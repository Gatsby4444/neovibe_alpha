-- Mode Mono (consigne Jay 2026-07-12) : nouveau type de card à face unique.
-- L'ajout de la valeur d'enum est isolé dans sa propre migration : une valeur
-- d'enum ne peut pas être UTILISÉE dans la transaction qui la crée.
alter type public.card_type add value if not exists 'mono';
