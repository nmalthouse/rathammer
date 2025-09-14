#version 420 core
#define NUM_LS 4
out vec4 FragColor;

in vec2 TexCoords;

layout(binding = 0) uniform sampler2D g_pos;
layout(binding = 1) uniform sampler2D g_norm;
layout(binding = 2) uniform sampler2D g_albedo;

layout(binding = 3) uniform sampler2DArray shadow_map;

layout (std140, binding = 0) uniform LightSpaceMatrices {
    mat4 lightSpaceMatrices[NUM_LS];
};

uniform float cascadePlaneDistances[NUM_LS];
uniform mat4 cam_view;
uniform vec3 view_pos;
uniform vec3 light_dir;
uniform vec4 light_color;
uniform vec4 ambient_color;
uniform vec2 screenSize;
uniform vec2 the_fucking_window_offset;

float shadowCalculation(vec3 fp, vec3 norm){
    vec4 fp_vs = cam_view * vec4(fp, 1.0);
    float depth = abs(fp_vs.z);
    int layer = NUM_LS - 1;
    for(int i = 0; i < NUM_LS; i++){
        if(depth < cascadePlaneDistances[i]){
            layer = i;
            break;
        }
    }
    mat4 ls = lightSpaceMatrices[layer];
    vec4 frag_pos_ls = ls * vec4(fp, 1.0);
    vec3 proj_coord = frag_pos_ls.xyz / frag_pos_ls.w;
    proj_coord = proj_coord * 0.5 + 0.5 ;

    float bb = 0.003; //0.005
    float bias = max(bb * (1.0 - dot(norm, light_dir)), bb);
    const float bias_mod = 0.1;
    bias *= 1 / (cascadePlaneDistances[layer] * bias_mod);

    float current_depth = proj_coord.z;

    float shadow = 0.0;
    vec2 texel_size = 1.0 / vec2(textureSize(shadow_map, 0));
    for(int x = -1; x <= 1; x++){
        for(int y = -1; y <= 1; y++){
            float pcf_depth = texture(shadow_map, vec3(proj_coord.xy  + vec2(x,y) * texel_size, layer)).r;
            shadow += (current_depth - bias) > pcf_depth ? 1.0: 0.0;
        }
    }
    shadow /= 9.0;
    return shadow;
}


float specular_strength = 0.1;

vec3 calculateDirLight(vec3 normal, vec3 ldir, vec4 lcolor, vec3 view_dir, float shadow){
    float diff = max(dot(normal, ldir), 0.1);
    vec3 diffuse1 = diff * lcolor.rgb * lcolor.a * 0.4 ;

    vec3 reflect_dir = reflect(-ldir, normal);
    float spec = pow(max(dot(view_dir, reflect_dir), 0.0), 32);
    vec3 specular = specular_strength * spec * lcolor.rgb;

    vec3 ambient = ambient_color.w * ambient_color.rgb;
    return  (diffuse1 + specular) * (1.0 - shadow) + ambient;
}

void main(){
    //FUCKING glFragcoord maps to window not viewport, come on.
    //Im glad they added an identifier to add 0.5 to each gl_FragCoord. That is a great use of space in the documentation. I would have found it very difficult to add 0.5 to gl_FragCoord myself.
    vec2 uv = ((gl_FragCoord.xy - the_fucking_window_offset) / screenSize);

    vec3 frag_pos = texture(g_pos, uv).rgb;
    vec3 normal = texture(g_norm, uv).rgb;
    vec3 diffuse = texture(g_albedo, uv).rgb;

    vec3 view_dir = normalize(view_pos - frag_pos);

    float shadow = shadowCalculation(frag_pos, normal);

    vec3 lights = calculateDirLight(normal, light_dir, light_color, view_dir, shadow);
    vec3 result =  lights * diffuse;


    FragColor = vec4(result, 1.0);
    //vec3 mapped = vec3(1.0) - exp(-result * exposure);
    //mapped = pow(mapped, vec3(1.0/gamma));
    //FragColor = vec4(mapped, 1.0);

}


