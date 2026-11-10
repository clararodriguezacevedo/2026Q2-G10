-- Flakiness: profesionales que aceptan trabajos y despues los sueltan (calidad sin ratings)
WITH ev AS (
  SELECT DISTINCT event_id, tipo, id_profesional
  FROM ${db}.eventos
  WHERE id_profesional IS NOT NULL
)
SELECT
  coalesce(u.nombre, ev.id_profesional) AS profesional,
  count_if(tipo = 'aceptar') AS aceptados,
  count_if(tipo = 'liberar') AS liberados,
  count_if(tipo = 'resolver') AS resueltos,
  round(100.0 * count_if(tipo = 'liberar') / count_if(tipo = 'aceptar'), 1) AS pct_abandono
FROM ev
LEFT JOIN ${db}.usuario u ON u.id = ev.id_profesional
GROUP BY 1
HAVING count_if(tipo = 'aceptar') > 0
ORDER BY pct_abandono DESC, liberados DESC
