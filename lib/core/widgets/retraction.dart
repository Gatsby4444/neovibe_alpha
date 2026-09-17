import 'dart:math' as math;

import 'package:flutter/material.dart';

/// **La forme qui se rétracte** : du plein écran (t = 0) vers un heptagone aux
/// sommets arrondis et aux côtés légèrement creusés (t = 1).
///
/// Demande de Jay, 2026-09-17 : *« si l'on dézoome avec deux doigts en mode
/// plein écran, cela le ferme, avec une animation dynamique progressive qui
/// suit le mouvement, et l'interface se rétracte en forme d'heptagone avec
/// côtés arrondis légèrement creusés vers l'intérieur »*.
///
/// ### Comment elle est construite
///
/// Le contour est décrit **en polaire** : pour chaque angle, un rayon. C'est
/// ce qui permet de passer d'un rectangle à un heptagone **sans saut** — deux
/// formes qui n'ont ni le même nombre de côtés ni les mêmes sommets ne
/// s'interpolent pas sommet par sommet, mais leurs rayons, si.
///
/// - rectangle : `min(a / |cos θ|, b / |sin θ|)` ;
/// - heptagone régulier : `R · cos(π/n) / cos(φ)` où `φ` est l'angle ramené
///   dans un secteur — le rayon vaut `R` aux sommets et l'apothème au milieu
///   d'un côté ;
/// - **sommets arrondis** : ce rapport élevé à la puissance [arrondi] (< 1),
///   ce qui pousse la forme vers le cercle sans toucher aux côtés ;
/// - **côtés creusés** : un facteur qui vaut 1 aux sommets et `1 - creux` au
///   milieu de chaque côté.
///
/// Le tout se mélange linéairement : `r = r_rect + (r_hept − r_rect) · t`.
double rayonRetracte(
  double theta, {
  required double a,
  required double b,
  required double t,
  int cotes = 7,
  double creux = 0.13,
  double arrondi = 0.72,
}) {
  // Le rectangle, vu du centre.
  final cos = math.cos(theta).abs();
  final sin = math.sin(theta).abs();
  final rRect = math.min(
    cos < 1e-6 ? double.infinity : a / cos,
    sin < 1e-6 ? double.infinity : b / sin,
  );
  if (t <= 0) return rRect;

  // L'heptagone : un sommet vers le haut.
  final secteur = 2 * math.pi / cotes;
  final brut = (theta + math.pi / 2) % secteur;
  final phi = brut - secteur / 2; // −π/n … +π/n
  final r = math.min(a, b);
  final plat = math.cos(math.pi / cotes) / math.cos(phi);
  final normalise = phi / (math.pi / cotes); // −1 … 1
  final rHept =
      r * math.pow(plat, arrondi) * (1 - creux * (1 - normalise * normalise));

  return rRect + (rHept - rRect) * t.clamp(0.0, 1.0);
}

/// Le contour complet, échantillonné assez finement pour qu'aucun segment ne
/// se voie.
Path formeRetractee(Size taille, double t, {int points = 240}) {
  final a = taille.width / 2;
  final b = taille.height / 2;
  final centre = Offset(a, b);
  final chemin = Path();
  for (var i = 0; i <= points; i++) {
    final theta = 2 * math.pi * i / points;
    final r = rayonRetracte(theta, a: a, b: b, t: t);
    final p = centre + Offset(math.cos(theta) * r, math.sin(theta) * r);
    if (i == 0) {
      chemin.moveTo(p.dx, p.dy);
    } else {
      chemin.lineTo(p.dx, p.dy);
    }
  }
  return chemin..close();
}

/// Le découpeur, pour poser [formeRetractee] sur un écran.
class RetractionClipper extends CustomClipper<Path> {
  const RetractionClipper(this.t);

  final double t;

  @override
  Path getClip(Size size) => formeRetractee(size, t);

  @override
  bool shouldReclip(RetractionClipper oldClipper) => oldClipper.t != t;
}
