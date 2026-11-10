-- Fill rate: porcentaje de solicitudes aceptadas dentro de las 48 h, por zona (las peores primero)
WITH ev AS (
  SELECT DISTINCT event_id, tipo, id_solicitud, id_zona, from_iso8601_timestamp(ts) AS ts
  FROM ${db}.eventos
),
creadas AS (
  SELECT id_solicitud, id_zona, min(ts) AS creada
  FROM ev WHERE tipo = 'creada'
  GROUP BY 1, 2
),
aceptadas AS (
  SELECT id_solicitud, min(ts) AS aceptada
  FROM ev WHERE tipo = 'aceptar'
  GROUP BY 1
)
SELECT
  coalesce(z.nombre, cast(c.id_zona AS varchar)) AS zona,
  count(*) AS solicitudes,
  count_if(a.aceptada <= c.creada + INTERVAL '48' HOUR) AS aceptadas_en_48h,
  round(100.0 * count_if(a.aceptada <= c.creada + INTERVAL '48' HOUR) / count(*), 1) AS fill_rate_48h
FROM creadas c
LEFT JOIN aceptadas a ON a.id_solicitud = c.id_solicitud
LEFT JOIN ${db}.zona z ON z.id = c.id_zona
-- Solo las que ya tuvieron 48 h para conseguir profesional
WHERE c.creada <= current_timestamp - INTERVAL '48' HOUR
GROUP BY 1
ORDER BY fill_rate_48h ASC, solicitudes DESC
