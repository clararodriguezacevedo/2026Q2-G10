-- Integridad de la urgencia: que parte de las solicitudes se marca con cada urgencia y si las urgentes se aceptan mas rapido
WITH ev AS (
  SELECT DISTINCT event_id, tipo, id_solicitud, id_urgencia, from_iso8601_timestamp(ts) AS ts
  FROM ${db}.eventos
),
creadas AS (
  SELECT id_solicitud, id_urgencia, min(ts) AS creada
  FROM ev WHERE tipo = 'creada'
  GROUP BY 1, 2
),
aceptadas AS (
  SELECT id_solicitud, min(ts) AS aceptada
  FROM ev WHERE tipo = 'aceptar'
  GROUP BY 1
)
SELECT
  coalesce(u.nombre, cast(c.id_urgencia AS varchar)) AS urgencia,
  count(*) AS solicitudes,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_del_total,
  round(approx_percentile(date_diff('minute', c.creada, a.aceptada), 0.5) / 60.0, 1) AS horas_hasta_aceptar_p50
FROM creadas c
LEFT JOIN aceptadas a ON a.id_solicitud = c.id_solicitud
LEFT JOIN ${db}.urgencia u ON u.id = c.id_urgencia
GROUP BY 1, c.id_urgencia
ORDER BY c.id_urgencia DESC
