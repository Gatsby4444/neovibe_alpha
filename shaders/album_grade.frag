#version 460 core
#include <flutter/runtime_effect.glsl>

// ===========================================================================
// LE SHADER DE L'ÉDITEUR D'ALBUM — aperçu et export d'une PHOTO
// ===========================================================================
//
// La même formule vit deux fois : ici pour Flutter (aperçu à l'écran, export
// photo), et dans `MediaTranscoder.kt` pour la vidéo. Le contrat entre les
// deux est `ColorGrade.toUniforms()` (24 nombres) + la géométrie
// `CropGeometry.corners()` (les coins du cadre dans l'image source).
//
// Étapes, dans cet ordre, identiques côté GL :
//   1. le cadre → la source : interpolation affine des trois coins ;
//   2. la matrice de couleurs 4×4 + offsets (luminosité, contraste,
//      saturation, chaleur, teinte, fondu) ;
//   3. ombres et hautes lumières (non linéaires, pondérées par la luminance) ;
//   4. netteté (masque flou soustrait sur quatre voisins) ;
//   5. vignette (smoothstep de 0,45 à 1 sur la distance au centre, 70 % max).
// ===========================================================================

uniform vec2 uSize;          // 0-1   taille du rectangle dessiné
uniform vec2 uOrigin;        // 2-3   coin haut-gauche du rectangle dessiné
uniform vec2 uTL;            // 4-5   coin haut-gauche du cadre, dans la source (0..1)
uniform vec2 uTR;            // 6-7   coin haut-droit
uniform vec2 uBL;            // 8-9   coin bas-gauche
uniform mat4 uColor;         // 10-25 matrice de couleurs (colonnes)
uniform vec4 uOffset;        // 26-29 offsets, en 0..1
uniform float uShadows;      // 30
uniform float uHighlights;   // 31
uniform float uSharpen;      // 32
uniform float uVignette;     // 33
uniform vec2 uTexel;         // 34-35 1 / taille de la source, pour la netteté

uniform sampler2D uImage;

out vec4 fragColor;

const vec3 kLuma = vec3(0.2126, 0.7152, 0.0722);

vec2 sourceUv(vec2 p) {
    return uTL + p.x * (uTR - uTL) + p.y * (uBL - uTL);
}

vec3 graded(vec3 c) {
    vec4 g = uColor * vec4(c, 1.0) + uOffset;
    vec3 rgb = clamp(g.rgb, 0.0, 1.0);
    float luma = dot(rgb, kLuma);
    // Ombres : les zones sombres (poids (1−luma)²) remontent ou s'enfoncent.
    float ws = (1.0 - luma) * (1.0 - luma);
    rgb += uShadows * 0.25 * ws;
    // Hautes lumières : les zones claires (poids luma²).
    float wh = luma * luma;
    rgb += uHighlights * 0.25 * wh;
    return clamp(rgb, 0.0, 1.0);
}

void main() {
    vec2 p = (FlutterFragCoord().xy - uOrigin) / uSize;
    vec2 uv = sourceUv(p);
    vec3 c = texture(uImage, uv).rgb;
    vec3 rgb = graded(c);

    if (uSharpen > 0.0) {
        vec3 n = graded(texture(uImage, uv + vec2(uTexel.x, 0.0)).rgb)
               + graded(texture(uImage, uv - vec2(uTexel.x, 0.0)).rgb)
               + graded(texture(uImage, uv + vec2(0.0, uTexel.y)).rgb)
               + graded(texture(uImage, uv - vec2(0.0, uTexel.y)).rgb);
        vec3 blur = n * 0.25;
        rgb = clamp(rgb + uSharpen * 0.8 * (rgb - blur), 0.0, 1.0);
    }

    // Vignette : la même courbe que `Vignette.alphaAt` côté Dart.
    float d = length(p - vec2(0.5)) / 0.70710678;
    float t = clamp((d - 0.45) / 0.55, 0.0, 1.0);
    float s = t * t * (3.0 - 2.0 * t);
    float a = min(uVignette * 0.7, 0.7) * s;
    fragColor = vec4(mix(rgb, vec3(0.0), a), 1.0);
}
