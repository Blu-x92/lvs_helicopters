AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "cl_camera.lua" )
AddCSLuaFile( "sh_camera_eyetrace.lua" )
AddCSLuaFile( "cl_hud.lua" )
AddCSLuaFile( "cl_flyby.lua" )
include("shared.lua")
include("sv_ai.lua")
include("sv_mouseaim.lua")
include("sv_components.lua")
include("sv_engine.lua")
include("sv_vehiclespecific.lua")
include("sv_damage_extension.lua")
include("sh_camera_eyetrace.lua")

function ENT:OnCreateAI()
	self:StartEngine()
	self.COL_GROUP_OLD = self:GetCollisionGroup()
	self:SetCollisionGroup( COLLISION_GROUP_INTERACTIVE_DEBRIS )
end

function ENT:OnRemoveAI()
	self:StopEngine()
	self:SetCollisionGroup( self.COL_GROUP_OLD or COLLISION_GROUP_NONE )
end

function ENT:ApproachTargetAngle( TargetAngle, OverridePitch, OverrideYaw, OverrideRoll, FreeMovement, phys, deltatime )
	if not IsValid( phys ) then
		phys = self:GetPhysicsObject()
	end

	if not deltatime then
		deltatime = FrameTime()
	end

	local LocalAngles = self:WorldToLocalAngles( TargetAngle )

	local LocalAngPitch = LocalAngles.p
	local LocalAngYaw = LocalAngles.y
	local LocalAngRoll = LocalAngles.r

	local TargetForward = TargetAngle:Forward()
	local Forward = self:GetForward()

	local Ang = self:GetAngles()
	local AngVel = phys:GetAngleVelocity()

	local SmoothPitch = math.Clamp( math.Clamp(AngVel.y / 50,-0.25,0.25) / math.abs( LocalAngPitch ), -1, 1 )
	local SmoothYaw = math.Clamp( math.Clamp(AngVel.z / 50,-0.25,0.25) / math.abs( LocalAngYaw ), -1, 1 )

	local VelL = self:WorldToLocal( self:GetPos() + self:GetVelocity() )

	local Pitch = math.Clamp(-LocalAngPitch / 10 + SmoothPitch,-1,1)
	local Yaw = math.Clamp(-LocalAngYaw + SmoothYaw,-1,1)

	if self:GetThrottle() <= 0.5 then self.Roll = Ang.r end

	self.Roll = self.Roll and self.Roll + ((OverrideRoll or 0) * self.TurnRateRoll * 70 * deltatime) or 0
	local Roll = math.Clamp( self:WorldToLocalAngles( Angle(Ang.p,Ang.y,self.Roll) ).r / 45, -1 , 1)

	if OverridePitch and OverridePitch ~= 0 then
		Pitch = OverridePitch
	end

	if OverrideYaw and OverrideYaw ~= 0 then
		Yaw = OverrideYaw
	end

	self:SetSteer( Vector( Roll, -Pitch, -Yaw) )
end

function ENT:OnSkyCollide( data, PhysObj )

	local NewVelocity = self:VectorSubtractNormal( data.HitNormal, data.OurOldVelocity ) - data.HitNormal * 50

	PhysObj:SetVelocityInstantaneous( NewVelocity )
	PhysObj:SetAngleVelocityInstantaneous( data.OurOldAngularVelocity )

	return true
end

function ENT:PhysicsSimulate( phys, deltatime )
	if self:GetEngineActive() then phys:Wake() end

	local WorldGravity = self:GetWorldGravity()
	local WorldUp = self:GetWorldUp()

	local Up = self:GetUp()
	local Left = -self:GetRight()

	local Mul = self:GetThrottle()
	local InputThrust = math.min( self:GetThrust() , 0 ) * self.ThrustDown + math.max( self:GetThrust(), 0 ) * self.ThrustUp

	if self:HitGround() and InputThrust <= 0 then
		Mul = 0
	end

	-- mouse aim needs to run at high speed.
	if self:GetAI() then
		self:CalcAIMove( phys, deltatime )
	else
		local ply = self:GetDriver()
		if IsValid( ply ) and ply:lvsMouseAim() then
			self:PlayerMouseAim( ply, phys, deltatime )
		end
	end

	local Steer = self:GetSteer()

	local Vel = phys:GetVelocity()
	local VelL = phys:WorldToLocal( phys:GetPos() + Vel )

	local YawPull = (math.deg( math.acos( math.Clamp( WorldUp:Dot( Left ) ,-1,1) ) ) - 90) /  90

	local GravityYaw = math.abs( YawPull ) ^ 1.25 * self:Sign( YawPull ) * (WorldGravity / 100) * (math.min( Vector(VelL.x,VelL.y,0):Length() / self.MaxVelocity,1) ^ 2)

	local Pitch = math.Clamp(Steer.y,-1,1) * self.TurnRatePitch
	local Yaw = math.Clamp(Steer.z + GravityYaw * 0.25,-1,1) * self.TurnRateYaw * 60
	local Roll = math.Clamp(Steer.x,-1,1) * 1.5 * self.TurnRateRoll

	local Ang = self:GetAngles()

	local FadeMul = (1 - math.max( (45 - self:AngleBetweenNormal( WorldUp, Up )) / 45,0)) ^ 2
	local ThrustMul = math.Clamp( 1 - (Vel:Length() / self.MaxVelocity) * FadeMul, 0, 1 )

	local Thrust = self:LocalToWorldAngles( Angle(Pitch,0,Roll) ):Up() * (WorldGravity + InputThrust * 500 * ThrustMul) * Mul

	local Force, ForceAng = phys:CalculateForceOffset( Thrust, phys:LocalToWorld( phys:GetMassCenter() ) + self:GetUp() * 1000 )

	local ForceLinear = (Force - Vel * 0.15 * self.ForceLinearDampingMultiplier) * Mul
	local ForceAngle = (ForceAng + (Vector(0,0,Yaw) - phys:GetAngleVelocity() * 1.5 * self.ForceAngleDampingMultiplier) * deltatime * 250) * Mul

	if self._SteerOverride then
		ForceAngle.z = (self._SteerOverrideMove * math.max( self:GetThrust() * 2, 1 ) * 100 - phys:GetAngleVelocity().z) * Mul
	end

	return ForceAngle, ForceLinear, SIM_GLOBAL_ACCELERATION
end

function ENT:ApproachThrust( New, Delta )
	if not Delta then
		Delta = FrameTime()
	end

	local Cur = self:GetThrust()

	self:SetThrust( Cur + (New - Cur) * Delta * self.ThrustRate * 2.5 )
end

function ENT:CalcThrust( KeyUp, KeyDown, Delta )
	if self:HitGround() and not KeyUp then
		self:ApproachThrust( -1, Delta )
		self.Roll = self:GetAngles().r

		return
	end

	local Up = KeyUp and 1 or 0
	local Down = KeyDown and -1 or 0

	self:ApproachThrust( Up + Down, Delta )
end

function ENT:CalcHover( InputLeft, InputRight, InputUp, InputDown, ThrustUp, ThrustDown, PhysObj, deltatime )
	if not IsValid( PhysObj ) then
		PhysObj = self:GetPhysicsObject()
	end

	local VelL = PhysObj:WorldToLocal( PhysObj:GetPos() + PhysObj:GetVelocity() )
	local AngVel = PhysObj:GetAngleVelocity()

	local KeyLeft = InputLeft and 60 or 0
	local KeyRight = InputRight and 60 or 0
	local KeyPitchUp = InputUp and 60 or 0
	local KeyPitchDown = InputDown and 60 or 0

	local Pitch = KeyPitchDown - KeyPitchUp
	local Roll = KeyRight - KeyLeft

	if (Pitch + Roll) == 0 then
		Pitch = math.Clamp(-VelL.x / 200,-1,1) * 60
		Roll = math.Clamp(VelL.y / 250,-1,1) * 60
	end

	local Ang = self:GetAngles()

	local Steer = self:GetSteer()
	Steer.x = math.Clamp( Roll - Ang.r - AngVel.x,-1,1)
	Steer.y = math.Clamp( Pitch - Ang.p - AngVel.y,-1,1)

	self:SetSteer( Steer )

	self.Roll = Ang.r

	if ThrustUp or ThrustDown then
		self:CalcThrust( ThrustUp, ThrustDown, deltatime )

		return
	end

	self:ApproachThrust( math.Clamp(-VelL.z / 100,-1,1), deltatime )
end
