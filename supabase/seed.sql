-- Exemples d'exercices, à remplacer par la vraie liste transmise par le coach.
insert into exercises (name, category, description) values
  ('Course à pied 30 min', 'cardio', 'Endurance fondamentale, allure modérée'),
  ('Squats', 'muscu', '4 séries de 12 répétitions'),
  ('Pompes', 'muscu', '4 séries de 15 répétitions'),
  ('Gainage', 'muscu', '3 x 45 secondes'),
  ('Corde à sauter', 'cardio', '3 x 5 minutes');

-- Pour désigner le super_admin (un seul, à faire une fois manuellement en base) :
-- update profiles set role = 'super_admin', status = 'active' where id = '<uuid de ton compte>';

-- Pour valider manuellement un compte en attente sans passer par le panel admin :
-- update profiles set status = 'active' where id = '<uuid du compte>';
