#version 460 core
#include <flutter/runtime_effect.glsl>

// LIQUID GLASS — réfraction réelle de l'arrière-plan.
//
// Écrit le 2026-08-14 après le rejet de la première version par Jay : « il n'y
// a pas l'effet liquid glass ». Il avait raison. La première version était du
// verre DÉPOLI — flou, teinte, liseré irisé peint à la main. Ce n'est pas la
// même chose.
//
// Ce qui fait le liquid glass, et qui manquait entièrement :
//
//   1. La RÉFRACTION. Le fond est courbé comme par une lentille : fortement au
//      bord, pas du tout au centre. C'est ça, et rien d'autre, qui donne
//      l'impression d'un objet épais posé sur le contenu plutôt que d'un voile.
//   2. La DISPERSION chromatique. Le verre ne dévie pas toutes les longueurs
//      d'onde également : rouge et bleu se séparent au bord. **C'est de là que
//      naît l'irisation** — je la peignais au feutre, elle doit être une
//      conséquence.
//   3. Le REFLET SPÉCULAIRE, calculé depuis la pente réelle de la surface, donc
//      cohérent avec la courbure.
//
// ## Le modèle
//
// On ne simule pas un volume : on se donne un CHAMP DE HAUTEUR `h(p)` (l'épaisseur
// du verre en chaque point), et tout découle de sa PENTE. Une surface plate ne
// dévie rien ; une surface inclinée dévie proportionnellement à son inclinaison.
//
// Le champ combine deux formes : la dalle du rail, et le bombé de chaque bouton
// posé dessus. Les deux bords produisent donc leur propre réfraction — c'est
// pour ça que les boutons se lisent comme des lentilles distinctes ET que le
// rail se lit comme une plaque.
//
// ## Un seul passage pour tout le rail
//
// Les boutons sont dans CE shader, pas dans six filtres séparés. Un
// `BackdropFilter` par bouton aurait multiplié par sept la lecture du tampon
// d'affichage. Ici : une lecture, une passe, six lentilles. C'est possible
// parce que les boutons sont régulièrement espacés — le shader retrouve le plus
// proche par le calcul, sans boucle ni tableau d'uniformes.

precision highp float;

// ⚠️ Le PREMIER uniforme doit être un `vec2` — contrat de `ImageFilter.shader`.
uniform vec2 uSize;

uniform float uRailRadius;   // rayon des coins du rail
uniform float uRailBevel;    // largeur du biseau du rail (son « épaisseur »)
uniform float uRefract;      // amplitude du déplacement, en pixels
uniform float uDispersion;   // écart entre les canaux R et B, en fraction
uniform float uSpecular;     // intensité du reflet
uniform float uTint;         // voile clair ajouté par-dessus

uniform float uBtnCount;     // 0 = rail seul, sans lentilles
uniform float uBtnRadius;
uniform float uBtnBevel;
uniform float uBtnFirstY;    // centre du premier bouton
uniform float uBtnStep;      // écart entre deux centres
uniform float uBtnCenterX;

// L'arrière-plan. Lié automatiquement par `BackdropFilter` : ne JAMAIS
// l'alimenter avec `setImageSampler`, ce serait écraser ce que Flutter y met.
uniform sampler2D uTexture;

out vec4 fragColor;

// Distance signée à un rectangle arrondi. Négative à l'intérieur.
float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

// Distance signée au bouton le plus proche.
//
// Les centres sont alignés et régulièrement espacés : l'indice du plus proche
// se calcule directement depuis y, sans parcourir la liste. Une boucle à borne
// dynamique se déroule mal sur certains pilotes — autant ne pas en avoir.
float sdNearestButton(vec2 p) {
  if (uBtnCount < 0.5) return 1e5;
  float i = clamp(
    floor((p.y - uBtnFirstY) / uBtnStep + 0.5),
    0.0,
    uBtnCount - 1.0
  );
  vec2 c = vec2(uBtnCenterX, uBtnFirstY + i * uBtnStep);
  return length(p - c) - uBtnRadius;
}

// Profil du biseau : 0 sur le bord, 1 une fois la largeur `w` franchie.
//
// Quart de cercle plutôt que rampe linéaire. C'est ce qui donne une pente
// INFINIE au bord exact et nulle au centre — donc une réfraction qui explose
// sur le liseré et disparaît au milieu. Une rampe linéaire donnerait une
// déviation constante, qui se lit comme un décalage, pas comme du verre.
float bevel(float dist, float w) {
  float t = clamp(dist / w, 0.0, 1.0);
  float u = 1.0 - t;
  return sqrt(max(0.0, 1.0 - u * u));
}

// Le champ de hauteur : la dalle du rail, plus le bombé des boutons.
float heightAt(vec2 p) {
  float dRail = sdRoundedBox(p - uSize * 0.5, uSize * 0.5, uRailRadius);
  float hRail = bevel(-dRail, uRailBevel);
  float hBtn = bevel(-sdNearestButton(p), uBtnBevel);
  // Le bouton n'ajoute que 45 % : il bombe sur la dalle, il ne la remplace pas.
  return hRail * (0.55 + 0.45 * hBtn);
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 uv = fc / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  // Hors du rail : on rend l'arrière-plan intact. Le découpage s'en charge
  // déjà, mais un shader qui ne salit rien hors de sa forme est un shader
  // qu'on peut déplacer sans surprise.
  float dRail = sdRoundedBox(fc - uSize * 0.5, uSize * 0.5, uRailRadius);
  if (dRail > 1.0) {
    fragColor = texture(uTexture, uv);
    return;
  }

  // Pente de la surface, par différences finies. Deux pixels d'écart : assez
  // large pour ne pas amplifier le bruit du SDF, assez fin pour que le liseré
  // reste net.
  const float e = 1.0;
  float hL = heightAt(fc - vec2(e, 0.0));
  float hR = heightAt(fc + vec2(e, 0.0));
  float hD = heightAt(fc - vec2(0.0, e));
  float hU = heightAt(fc + vec2(0.0, e));
  vec2 slope = vec2(hR - hL, hU - hD) / (2.0 * e);

  // La déviation suit la pente, en sens inverse : là où le verre s'incline, il
  // ramène vers lui l'image qui passait à côté. C'est l'effet loupe du bord.
  vec2 offset = -slope * uRefract;

  // Dispersion : le rouge dévie un peu plus que le bleu. Les trois canaux sont
  // échantillonnés séparément — c'est trois lectures au lieu d'une, et c'est le
  // prix de l'irisation. Sans elle, le bord est gris et l'effet retombe à plat.
  vec2 duv = offset / uSize;
  vec3 col;
  col.r = texture(uTexture, uv + duv * (1.0 + uDispersion)).r;
  col.g = texture(uTexture, uv + duv).g;
  col.b = texture(uTexture, uv + duv * (1.0 - uDispersion)).b;

  // Reflet spéculaire, calculé depuis la VRAIE normale de la surface. Il tombe
  // donc exactement là où le verre s'incline : sur les liserés, jamais au
  // centre. La lumière vient d'en haut à gauche, comme partout dans l'app.
  vec3 normal = normalize(vec3(-slope * 40.0, 1.0));
  vec3 light = normalize(vec3(-0.55, -0.75, 0.62));
  float spec = pow(max(dot(normal, light), 0.0), 22.0);
  col += vec3(spec * uSpecular);

  // Voile clair : ce qui distingue une lentille (transparente) d'un matériau
  // (habitable). Il reste faible — le liquid glass laisse voir, contrairement
  // au verre dépoli qui masquait.
  col = mix(col, vec3(1.0), uTint);

  // Adoucissement du bord extérieur, pour que le rail ne soit pas découpé au
  // ciseau contre l'aperçu.
  float edge = smoothstep(1.0, -1.0, dRail);
  fragColor = vec4(col, 1.0) * edge + texture(uTexture, uv) * (1.0 - edge);
}
