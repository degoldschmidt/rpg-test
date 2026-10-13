class_name MovementConfig
extends Resource
## Every movement / ragdoll tunable lives here so feel can be tuned without code changes.

@export_group("Ground")
@export var walk_speed := 3.4
@export var run_speed := 7.5
@export var crouch_speed := 1.8
@export var walk_accel := 9.0         ## m/s^2 while below target speed
@export var run_accel := 4.5          ## lower accel above walk speed = momentum build-up
@export var ground_decel := 9.0       ## m/s^2 when above target speed with input
@export var ground_friction := 7.0    ## m/s^2 when no input
@export var turn_rate_slow := 12.0    ## rad/s at standstill
@export var turn_rate_fast := 3.2     ## rad/s at run speed (wide arcs)
@export var skid_angle_deg := 120.0   ## reversing beyond this angle at speed causes a skid
@export var skid_min_speed := 4.5
@export var skid_decel := 16.0

@export_group("Air")
@export var gravity := 24.0
@export var fall_gravity_mult := 1.6
@export var low_jump_gravity_mult := 2.6   ## applied while rising with jump released
@export var jump_height := 1.3
@export var air_accel := 5.0
@export var air_drag := 0.15
@export var terminal_speed := 45.0
@export var coyote_time := 0.12
@export var jump_buffer := 0.15

@export_group("Crouch & slide")
@export var stand_height := 1.8
@export var crouch_height := 1.1
@export var capsule_radius := 0.3
@export var slide_min_speed := 5.0
@export var slide_friction := 3.0
@export var slide_boost := 1.0

@export_group("Roll")
@export var roll_speed := 6.5
@export var roll_duration := 0.65
@export var roll_friction := 2.0
@export var roll_cooldown := 0.25
@export var roll_land_window := 0.3   ## roll pressed this long before landing = safe roll-landing

@export_group("Landing & ragdoll")
@export var stumble_land_speed := 14.0
@export var ragdoll_land_speed := 19.0
@export var roll_safe_land_speed := 30.0
@export var stumble_duration := 0.45
@export var limb_hit_threshold := 60.0     ## relative speed * mass, weakens a limb
@export var ragdoll_hit_threshold := 220.0 ## summed hit strength per tick, full ragdoll
@export var ragdoll_settle_speed := 0.6
@export var ragdoll_settle_time := 0.8
@export var ragdoll_min_time := 1.0
@export var get_up_time := 1.1
