## The flyable ships (ported from the Mac game's ShipModel definitions: Meshes.swift, CL505.swift, Atlas.swift).
## Positions are in model units, as in the Mac source; metres = units × size_m / length_u.
class_name Ships

const BLUE_FLAME := {"edge": Color(0.3, 0.6, 2.4), "core": Color(1.6, 2.2, 3.4), "glow": Color(0.6, 0.85, 1.4)}

static func roster() -> Array:
	var A := 1.0 / 650.0                  # Atlas: model units per metre
	return [
		{
			"name": "Kestrel", "pitch": 1.0, "role": "STRIKE FIGHTER", "file": "kestrel", "size_m": 50.0, "length_u": 1.4,
			"gear_u": 0.273, "speedK": 1.0, "agility": 1.0, "mass": 1.0,
			"engines": [[-0.15, 0.0, 0.586, 0.0414], [0.0, 0.0, 0.586, 0.0414], [0.15, 0.0, 0.586, 0.0414]],
			"nozzle_depth": 0.6,
			"legs": [[0.0, -0.09, -0.42], [0.3, -0.09, 0.26], [-0.3, -0.09, 0.26]], "leg_len": 0.17, "leg_r": 0.016, "pad_r": 0.05,
			"flame": BLUE_FLAME,
			"nav": [[-0.66, 0.02, 0.38, 0.1, Color(1, 0.23, 0.23)], [0.66, 0.02, 0.38, 0.1, Color(0.23, 1, 0.48)]],
			"steady": [[0.24, 0.07, -0.3, 0.06, Color(0.35, 0.66, 1)], [-0.24, 0.07, -0.3, 0.06, Color(0.35, 0.66, 1)], [0.0, 0.02, -0.82, 0.07, Color(1, 1, 1)]],
			"stats": [["SPEED", 0.55], ["AGILITY", 1.0], ["RANGE", 0.25], ["SIZE", 0.15]],
			"tags": ["the original", "three engines"],
		},
		{
			"name": "Heron", "pitch": 1.25, "role": "RACER", "file": "heron", "size_m": 26.0, "length_u": 1.4,
			"gear_u": 0.2, "speedK": 1.6, "agility": 1.35, "mass": 0.8,
			"engines": [[0.001, -0.037, 0.432, 0.034]], "nozzle_depth": 0.12,
			"legs": [], "leg_len": 0.0, "leg_r": 0.0, "pad_r": 0.0,
			"flame": {"edge": Color(2.0, 0.25, 0.08), "core": Color(3.0, 0.9, 0.35), "glow": Color(1.6, 0.28, 0.1)},
			"nav": [[-0.25, 0.0, 0.45, 0.06, Color(1, 0.23, 0.23)], [0.25, 0.0, 0.45, 0.06, Color(0.23, 1, 0.48)]],
			"steady": [[0.0, 0.0, -0.7, 0.05, Color(1, 1, 1)]],
			"stats": [["SPEED", 1.0], ["AGILITY", 1.0], ["RANGE", 0.35], ["SIZE", 0.08]],
			"tags": ["the fastest", "model by Jungle Jim · CC BY"],
		},
		{
			"name": "Atlas", "pitch": 0.4, "role": "HEAVY CRUISER", "file": "cruiser", "size_m": 1300.0, "length_u": 2.0,
			"gear_u": (82.0 + 58.0 + 4.0) * A, "exit_side": 0.2, "speedK": 1.2, "agility": 0.28, "mass": 3.8,
			"engines": [[64.8 * A, -23.3 * A, 579.0 * A, 8.0 * A], [-64.8 * A, -23.3 * A, 579.0 * A, 8.0 * A], [82.8 * A, -23.3 * A, 575.0 * A, 8.0 * A],
						[-82.8 * A, -23.3 * A, 575.0 * A, 8.0 * A], [100.5 * A, -23.3 * A, 568.0 * A, 8.0 * A], [-100.5 * A, -23.3 * A, 568.0 * A, 8.0 * A]],
			"nozzle_depth": 30.0 * A,
			"legs": [[55 * A, -82 * A, 40 * A], [-55 * A, -82 * A, 40 * A], [60 * A, -82 * A, 170 * A], [-60 * A, -82 * A, 170 * A],
					 [55 * A, -82 * A, 300 * A], [-55 * A, -82 * A, 300 * A]],
			"leg_len": 58 * A, "leg_r": 6 * A, "pad_r": 17 * A,
			"flame": BLUE_FLAME,
			"nav": [[-150 * A, -6 * A, 360 * A, 0.05, Color(1, 0.23, 0.23)], [150 * A, -6 * A, 360 * A, 0.05, Color(0.23, 1, 0.48)],
					[0.0, 92 * A, 320 * A, 0.04, Color(1, 0.3, 0.3)]],
			"steady": [[0.0, 2 * A, -650 * A, 0.04, Color(1, 1, 1)]],
			"chase": Vector3(430.0, 160.0, 950.0), "cam_scale": 0.5,
			"stats": [["SPEED", 0.65], ["AGILITY", 0.25], ["RANGE", 1.0], ["SIZE", 1.0]],
			"tags": ["1.3 km mothership", "walk aboard (I)", "landing pad", "model by xaxary · CC BY"],
		},
		{
			"name": "CL505", "pitch": 1.1, "role": "INTERCEPTOR", "file": "cl505", "size_m": 32.0, "length_u": 1.4,
			"gear_u": 0.197, "speedK": 1.15, "agility": 1.15, "mass": 0.9,
			"engines": [[0.182, 0.024, 0.54, 0.048], [-0.182, 0.024, 0.54, 0.048], [0.066, 0.1, 0.548, 0.02], [-0.066, 0.1, 0.548, 0.02],
						[0.31, 0.018, 0.56, 0.018], [-0.31, 0.018, 0.56, 0.018]],
			"nozzle_depth": 0.1,
			"legs": [], "leg_len": 0.0, "leg_r": 0.0, "pad_r": 0.0,
			"flame": {"edge": Color(0.25, 0.5, 2.4), "core": Color(1.2, 1.8, 3.4), "glow": Color(1.4, 0.35, 0.18)},
			"nav": [[-0.63, 0.0, 0.3, 0.07, Color(1, 0.23, 0.23)], [0.63, 0.0, 0.3, 0.07, Color(0.23, 1, 0.48)]],
			"steady": [[0.0, 0.0, -0.7, 0.06, Color(1, 1, 1)]],
			"stats": [["SPEED", 0.7], ["AGILITY", 1.0], ["RANGE", 0.3], ["SIZE", 0.1]],
			"tags": ["fast and nimble", "model by Jungle Jim · CC BY"],
		},
	]
