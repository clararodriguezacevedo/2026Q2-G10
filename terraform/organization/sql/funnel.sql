-- Funnel de dos lados: cuantas solicitudes llegan a cada etapa y cuantas se cancelan
WITH ev AS (
  SELECT DISTINCT event_id, tipo, id_solicitud
  FROM ${db}.eventos
)
SELECT
  count(DISTINCT CASE WHEN tipo = 'creada' THEN id_solicitud END) AS creadas,
  count(DISTINCT CASE WHEN tipo = 'aceptar' THEN id_solicitud END) AS aceptadas,
  count(DISTINCT CASE WHEN tipo = 'iniciar' THEN id_solicitud END) AS iniciadas,
  count(DISTINCT CASE WHEN tipo = 'resolver' THEN id_solicitud END) AS resueltas,
  count(DISTINCT CASE WHEN tipo = 'calificada' THEN id_solicitud END) AS calificadas,
  count(DISTINCT CASE WHEN tipo = 'liberar' THEN id_solicitud END) AS liberadas_alguna_vez,
  count(DISTINCT CASE WHEN tipo = 'cancelar' THEN id_solicitud END) AS canceladas
FROM ev
