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

@export_group("Ledges")
@export var ledge_reach := 0.75          ## wall probe distance from the capsule center
@export var mantle_min_height := 0.6     ## lower ledges are just stepped/jumped onto
@export var mantle_max_height := 1.6     ## ground mantle (press jump facing the ledge)
@export var air_mantle_max_height := 1.3 ## mid-air: ledge at most this far above the feet = mantle
@export var grab_max_height := 2.3       ## mid-air: up to this = grab and hang
@export var grab_min_vy := -10.0         ## falling faster than this, hands can't hold
@export var hang_hand_height := 2.03     ## ledge height above the feet while hanging
@export var hang_wall_gap := 0.38        ## capsule center to wall while hanging
@export var shimmy_speed := 1.2
@export var climb_up_time := 0.9         ## from hanging
@export var mantle_time_low := 0.35      ## ground mantle at mantle_min_height
@export var mantle_time_high := 0.65     ## ground mantle at mantle_max_height
@export var regrab_cooldown := 0.5

@export_group("Objects")
@export var interact_range := 1.0        ## reach in front of the chest
@export var lift_max_mass := 25.0        ## heavier objects can only be pushed / pulled
@export var push_max_mass := 300.0       ## heavier objects can't be moved at all
@export var lift_strength := 600.0       ## N, total hold force (incl. gravity compensation)
@export var carry_height := 1.15         ## object center above the feet
@export var carry_speed_penalty := 0.45  ## speed lost carrying lift_max_mass
@export var throw_speed := 9.0           ## for a throw_ref_mass object
@export var throw_ref_mass := 6.0
@export var push_strength := 1600.0      ## N, horizontal force on a pushed / pulled object
@export var push_speed_light := 2.2
@export var push_speed_heavy := 0.6      ## at push_max_mass
@export var grab_gap := 0.5              ## capsule center to grabbed face
@export var grab_break_distance := 0.45

@export_group("Combat")
@export var stagger_strength := 1.8      ## hit strength (punch 1.0, kick 2.2) that staggers
@export var knockdown_strength := 3.0    ## ... that knocks down (running kick, or hit while staggered)
@export var guard_break_strength := 2.0  ## guard holds below this
@export var guard_break_time := 0.8
@export var guard_speed_factor := 0.4
@export var block_pushback := 1.2
@export var combo_window := 0.6          ## third light hit inside this window staggers
@export var stagger_time := 0.6
@export var stagger_speed := 3.0
@export var stagger_friction := 5.0
@export var flinch_speed := 4.0          ## velocity given to the struck limb per strength unit
@export var knockdown_speed := 5.0
@export var lock_on_range := 3.0

@export_group("Performance")
@export var lod_full_range := 25.0       ## closer than this to the LOD focus: full active ragdoll
@export var lod_kinematic_range := 60.0  ## closer than this: kinematic puppet; beyond: proxy only
@export var pose_stride := 4             ## proxy-only tier animates every Nth tick
@export var lod_update_interval := 0.25
@export var lod_promote_hold := 3.0      ## stay FULL this long after a hit / ragdoll

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
