-- Cancelaciones con causa: desde que estado cancela el cliente y cuanto espero (PENDIENTE = falta de oferta)
WITH ev AS (
  SELECT DISTINCT event_id, tipo, id_solicitud, estado_anterior, from_iso8601_timestamp(ts) AS ts
  FROM ${db}.eventos
),
creadas AS (
  SELECT id_solicitud, min(ts) AS creada
  FROM ev WHERE tipo = 'creada'
  GROUP BY 1
)
SELECT
  x.estado_anterior AS cancelo_desde,
  count(*) AS cancelaciones,
  round(approx_percentile(date_diff('minute', c.creada, x.ts), 0.5) / 60.0, 1) AS horas_esperadas_p50,
  round(approx_percentile(date_diff('minute', c.creada, x.ts), 0.9) / 60.0, 1) AS horas_esperadas_p90
FROM ev x
JOIN creadas c ON c.id_solicitud = x.id_solicitud
WHERE x.tipo = 'cancelar'
GROUP BY 1
ORDER BY cancelaciones DESC
