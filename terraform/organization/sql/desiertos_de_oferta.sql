-- Desiertos de oferta: combinaciones de categoria y zona donde los trabajos no se toman o tardan (mediana y p90)
WITH ev AS (
  SELECT DISTINCT event_id, tipo, id_solicitud, id_categoria, id_zona, from_iso8601_timestamp(ts) AS ts
  FROM ${db}.eventos
),
creadas AS (
  SELECT id_solicitud, id_categoria, id_zona, min(ts) AS creada
  FROM ev WHERE tipo = 'creada'
  GROUP BY 1, 2, 3
),
aceptadas AS (
  SELECT id_solicitud, min(ts) AS aceptada
  FROM ev WHERE tipo = 'aceptar'
  GROUP BY 1
)
SELECT
  coalesce(cat.nombre, cast(c.id_categoria AS varchar)) AS categoria,
  coalesce(z.nombre, cast(c.id_zona AS varchar)) AS zona,
  count(*) AS solicitudes,
  count(*) - count(a.aceptada) AS nunca_aceptadas,
  round(approx_percentile(date_diff('minute', c.creada, a.aceptada), 0.5) / 60.0, 1) AS horas_hasta_aceptar_p50,
  round(approx_percentile(date_diff('minute', c.creada, a.aceptada), 0.9) / 60.0, 1) AS horas_hasta_aceptar_p90
FROM creadas c
LEFT JOIN aceptadas a ON a.id_solicitud = c.id_solicitud
LEFT JOIN ${db}.categoria cat ON cat.id = c.id_categoria
LEFT JOIN ${db}.zona z ON z.id = c.id_zona
GROUP BY 1, 2
ORDER BY nunca_aceptadas DESC, horas_hasta_aceptar_p90 DESC
