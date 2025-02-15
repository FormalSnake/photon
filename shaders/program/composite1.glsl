/*
--------------------------------------------------------------------------------

  Photon Shaders by SixthSurge

  program/composite1.glsl
  Apply volumetric fog, reflections and refraction

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"


//----------------------------------------------------------------------------//
#if defined vsh

out vec2 uv;

flat out vec3 ambient_color;
flat out vec3 light_color;

uniform sampler2D colortex4; // Sky map, lighting colors

void main() {
	uv = gl_MultiTexCoord0.xy;

	light_color   = texelFetch(colortex4, ivec2(191, 0), 0).rgb;
	ambient_color = texelFetch(colortex4, ivec2(191, 1), 0).rgb;

	vec2 vertex_pos = gl_Vertex.xy * taau_render_scale;
	gl_Position = vec4(vertex_pos * 2.0 - 1.0, 0.0, 1.0);
}

#endif
//----------------------------------------------------------------------------//



//----------------------------------------------------------------------------//
#if defined fsh

layout (location = 0) out vec3 scene_color;
layout (location = 1) out float bloomy_fog;

/* DRAWBUFFERS:03 */

in vec2 uv;

flat in vec3 ambient_color;
flat in vec3 light_color;

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform sampler2D colortex0; // Scene color
uniform sampler2D colortex1; // Gbuffer 0
uniform sampler2D colortex2; // Gbuffer 1
uniform sampler2D colortex4; // Sky map
uniform sampler2D colortex5; // Scene history
uniform sampler2D colortex6; // Volumetric fog scattering
uniform sampler2D colortex7; // Volumetric fog transmittance

uniform sampler2D depthtex0;
uniform sampler2D depthtex1;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

uniform float near;
uniform float far;

uniform float frameTimeCounter;
uniform float sunAngle;
uniform float rainStrength;
uniform float wetness;

uniform int worldTime;
uniform int frameCounter;

uniform int isEyeInWater;
uniform float blindness;
uniform float nightVision;
uniform float darknessFactor;

uniform vec3 light_dir;
uniform vec3 sun_dir;
uniform vec3 moon_dir;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

uniform float eye_skylight;

uniform float biome_cave;
uniform float biome_may_rain;
uniform float biome_may_snow;

uniform float time_sunrise;
uniform float time_noon;
uniform float time_sunset;
uniform float time_midnight;

// ------------
//   Includes
// ------------

#define TEMPORAL_REPROJECTION

#include "/include/fog/simple_fog.glsl"
#include "/include/light/specular.glsl"
#include "/include/misc/material.glsl"
#include "/include/misc/rain_puddles.glsl"
#include "/include/misc/water_normal.glsl"
#include "/include/utility/color.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/space_conversion.glsl"

/*
const bool colortex5MipmapEnabled = true;
*/

// https://iquilezles.org/www/articles/texture/texture.htm
vec4 smooth_filter(sampler2D sampler, vec2 coord) {
	vec2 res = vec2(textureSize(sampler, 0));

	coord = coord * res + 0.5;

	vec2 i, f = modf(coord, i);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	coord = i + f;

	coord = (coord - 0.5) / res;
	return texture(sampler, coord);
}

// http://www.diva-portal.org/smash/get/diva2:24136/FULLTEXT01.pdf
vec3 purkinje_shift(vec3 rgb, vec2 light_levels) {
#if !(defined PURKINJE_SHIFT && defined WORLD_OVERWORLD)
	return rgb;
#else
	float purkinje_intensity  = 0.05 * PURKINJE_SHIFT_INTENSITY;
	      purkinje_intensity  = purkinje_intensity - purkinje_intensity * smoothstep(-0.12, -0.06, sun_dir.y) * light_levels.y; // No purkinje shift in daylight
	      purkinje_intensity *= clamp01(1.0 - light_levels.x); // Reduce purkinje intensity in blocklight
	      purkinje_intensity *= clamp01(0.3 + 0.7 * cube(light_levels.y)); // Reduce purkinje intensity underground

	if (purkinje_intensity < eps) return rgb;

	const vec3 purkinje_tint = vec3(0.45, 0.66, 1.0);
	const vec3 rod_response = vec3(7.15e-5, 4.81e-1, 3.28e-1) * rec709_to_rec2020;

	vec3 xyz = rgb * rec2020_to_xyz;

	vec3 scotopic_luminance = xyz * (1.33 * (1.0 + (xyz.y + xyz.z) / xyz.x) - 1.68);

	float purkinje = dot(rod_response, scotopic_luminance * xyz_to_rec2020);

	rgb = mix(rgb, purkinje * purkinje_tint, exp2(-rcp(purkinje_intensity) * purkinje));

	return max0(rgb);
#endif
}

void main() {
	ivec2 texel = ivec2(gl_FragCoord.xy);

	// Sample textures

	scene_color         = texelFetch(colortex0, texel, 0).rgb;
	float depth0        = texelFetch(depthtex0, texel, 0).x;
	float depth1        = texelFetch(depthtex1, texel, 0).x;
	vec4 gbuffer_data_0 = texelFetch(colortex1, texel, 0);
#if defined NORMAL_MAPPING || defined SPECULAR_MAPPING
	vec4 gbuffer_data_1 = texelFetch(colortex2, texel, 0);
#endif

#if defined WORLD_OVERWORLD && defined VL
	vec2 fog_uv = clamp(uv * VL_RENDER_SCALE, vec2(0.0), floor(view_res * VL_RENDER_SCALE - 1.0) * view_pixel_size);
	vec3 fog_scattering    = smooth_filter(colortex6, fog_uv).rgb;
	vec3 fog_transmittance = smooth_filter(colortex7, fog_uv).rgb;
#endif

	// Sky early exit

	if (depth0 == 1.0) {
		// Apply volumetric fog
#if defined WORLD_OVERWORLD && defined VL
		scene_color = scene_color * fog_transmittance + fog_scattering;
		bloomy_fog = clamp01(dot(fog_transmittance, vec3(luminance_weights_rec2020)));
#endif

#if defined WORLD_NETHER
		bloomy_fog = spherical_fog(far, nether_fog_start, nether_bloomy_fog_density * (1.0 - blindness)) * 0.5 + 0.5;
#endif

		// Apply purkinje shift
		scene_color = purkinje_shift(scene_color, vec2(0.0, 1.0));

		return;
	}

	// Space conversions

	depth0 += 0.38 * float(depth0 < hand_depth); // Hand lighting fix from Capt Tatsu

	vec3 screen_pos = vec3(uv, depth0);
	vec3 view_pos   = screen_to_view_space(screen_pos, true);
	vec3 scene_pos  = view_to_scene_space(view_pos);
	vec3 world_pos  = scene_pos + cameraPosition;

	vec3 view_back_pos = screen_to_view_space(vec3(uv, depth1), true);

	vec3 world_dir; float view_dist;
	length_normalize(scene_pos - gbufferModelViewInverse[3].xyz, world_dir, view_dist);

	// Unpack gbuffer data

	mat4x2 data = mat4x2(
		unpack_unorm_2x8(gbuffer_data_0.x),
		unpack_unorm_2x8(gbuffer_data_0.y),
		unpack_unorm_2x8(gbuffer_data_0.z),
		unpack_unorm_2x8(gbuffer_data_0.w)
	);

	vec3 albedo        = vec3(data[0], data[1].x);
	uint material_mask = uint(255.0 * data[1].y);
	vec3 flat_normal   = decode_unit_vector(data[2]);
	vec2 light_levels  = data[3];

	Material material;
	vec3 normal = flat_normal;

	mat3 tbn = get_tbn_matrix(flat_normal);

	// Get material and normal

	bool is_water = material_mask == 1;

	//------------------------------------------------------------------------//
	if (is_water) {
		material = water_material;

		// Water waves

#ifdef WATER_WAVES
		if (flat_normal.y > 0.01 && isEyeInWater == 0
		 || flat_normal.y < 0.01 && isEyeInWater != 0
		) {
			vec2 coord = world_pos.xz;

			bool flowing_water = abs(flat_normal.y) < 0.99;
			vec2 flow_dir = flowing_water ? normalize(flat_normal.xz) : vec2(0.0);

#ifdef WATER_PARALLAX
			vec3 tangent_dir = world_dir * tbn;
			coord = get_water_parallax_coord(tangent_dir, coord, flow_dir, flowing_water);
#endif

			normal = tbn * get_water_normal(world_pos, flat_normal, coord, flow_dir, light_levels.y, flowing_water);
		}
#endif
	//------------------------------------------------------------------------//
	} else {
		material = material_from(albedo, material_mask, world_pos, light_levels);

#ifdef NORMAL_MAPPING
		normal = decode_unit_vector(gbuffer_data_1.xy);
#endif

#ifdef SPECULAR_MAPPING
		vec4 specular_map = vec4(unpack_unorm_2x8(gbuffer_data_1.z), unpack_unorm_2x8(gbuffer_data_1.w));

#if defined POM && defined POM_SHADOW
		// Specular map alpha > 0.5 => inside parallax shadow
		bool parallax_shadow = specular_map.a > 0.5;
		specular_map.a -= 0.5 * float(parallax_shadow);
		specular_map.a *= 2.0;
#endif

		decode_specular_map(specular_map, material);
#endif
	}

	// Refraction

	float layer_dist = abs(view_dist - length(view_back_pos));

	if (is_water) {
#ifdef WATER_REFRACTION
		vec3 tangent_normal = normal * tbn;

		vec2 refracted_uv = uv + tangent_normal.xy * rcp(max(view_dist, 1.0)) * min(layer_dist, 8.0) * (0.1 * WATER_REFRACTION_INTENSITY);

		vec3  refracted_color = texture(colortex0, refracted_uv * taau_render_scale).rgb;

		// Make sure the refracted object is behind water
		float refracted_data  = texelFetch(colortex1, ivec2(refracted_uv * taau_render_scale * view_res), 0).y;
		uint  refracted_mask  = uint(unpack_unorm_2x8(refracted_data).y * 255.0);

		if (refracted_mask == 1) scene_color = refracted_color;
#endif

#ifdef SNELLS_WINDOW
		if (isEyeInWater == 1.0) {
			float NoV = clamp01(dot(normal, -world_dir));
			float water_n = isEyeInWater == 1 ? air_n / water_n : water_n / air_n;
			scene_color *= 1.0 - fresnel_dielectric_n(NoV, water_n);
		}
#endif
	}

	// Rain puddles

#ifdef RAIN_PUDDLES
	if (!is_water && depth1 != 1.0) {
		bool puddle = get_rain_puddles(
			world_pos,
			flat_normal,
			light_levels,
			material.porosity,
			normal,
			material.f0,
			material.roughness,
			material.ssr_multiplier
		);

		if (puddle) {
			material.is_metal = false;
			material.is_hardcoded_metal = false;
		}
	}
#endif

	// Specular reflections

#if defined ENVIRONMENT_REFLECTIONS || defined SKY_REFLECTIONS
	if (material.ssr_multiplier > eps && depth0 < 1.0) {
		vec3 reflections = get_specular_reflections(
			material,
			tbn,
			screen_pos,
			view_pos,
			normal,
			flat_normal,
			world_dir,
			world_dir * tbn,
			light_levels.y
		);

#ifdef WATER_WAVES
		// Specular highlight for water (must be applied after water waves)
		if (is_water) {
			float NoL = dot(normal, light_dir);
			float NoV = clamp01(dot(normal, -world_dir));
			float LoV = dot(light_dir, -world_dir);
			float halfway_norm = inversesqrt(2.0 * LoV + 2.0);
			float NoH = (NoL + NoV) * halfway_norm;
			float LoH = LoV * halfway_norm + halfway_norm;

			vec3 shadows = vec3(data[0].xy, data[1].x);

			reflections += get_specular_highlight(material, NoL, NoV, NoH, LoV, LoH) * light_color * shadows;
		}
#endif

		reflections *= common_fog_alpha(length(scene_pos), false);
		reflections *= border_fog(scene_pos, world_dir);

		scene_color += reflections;
	}
#endif

	// Apply atmospheric fog

#if defined WORLD_OVERWORLD && defined VL
	scene_color = scene_color * fog_transmittance + fog_scattering;
	bloomy_fog = clamp01(dot(fog_transmittance, vec3(luminance_weights_rec2020)));
	bloomy_fog = isEyeInWater == 1.0 ? sqrt(bloomy_fog) : bloomy_fog;
#else
	if (isEyeInWater == 1) {
		// Simple underwater fog
		float LoV = dot(world_dir, light_dir);
		mat2x3 water_fog = water_fog_simple(light_color, ambient_color, water_absorption_coeff, view_dist, LoV, eye_skylight, 15.0 - 15.0 * eye_skylight);

		scene_color *= water_fog[1];
		scene_color += water_fog[0];

		bloomy_fog = sqrt(clamp01(dot(water_fog[1], vec3(0.33))));
	} else {
		bloomy_fog = 1.0;
	}
#endif

#if defined WORLD_NETHER
	bloomy_fog = spherical_fog(view_dist, nether_fog_start, nether_bloomy_fog_density) * 0.33 + 0.67;
#endif

	// Apply purkinje shift
	scene_color = purkinje_shift(scene_color, light_levels);
}

#endif
//----------------------------------------------------------------------------//
