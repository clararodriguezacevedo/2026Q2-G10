"""Tests de barriofix.eventos: del registro del Stream al evento de negocio.

Corren con la stdlib, sin AWS:
    PYTHONPATH=back/layers/common/python python -m unittest discover -s back/tests
"""

import unittest

from barriofix.eventos import deserializar, desde_registro_stream


def _meta(**campos):
    """META de una solicitud en DynamoDB JSON, con valores por defecto."""
    base = {
        "PK": {"S": "SOL#01JABC"},
        "SK": {"S": "META"},
        "id_solicitud": {"S": "01JABC"},
        "estado": {"S": "PENDIENTE"},
        "id_categoria": {"N": "3"},
        "id_zona": {"N": "21"},
        "id_urgencia": {"N": "2"},
        "id_cliente": {"S": "sub-cliente"},
        "fecha_creacion": {"S": "2026-11-10T10:00:00+00:00"},
        "fecha_actualizacion": {"S": "2026-11-10T10:00:00+00:00"},
        "fotos": {"M": {}},
    }
    base.update(campos)
    return base


def _registro(event_name, nueva, vieja=None):
    dynamo = {"ApproximateCreationDateTime": 1794400000, "NewImage": nueva}
    if vieja is not None:
        dynamo["OldImage"] = vieja
    return {"eventID": "ev-1", "eventName": event_name, "dynamodb": dynamo}


def _con_profesional(**campos):
    return _meta(id_profesional={"S": "sub-pro"}, **campos)


class DesdeRegistroStream(unittest.TestCase):
    def test_insert_es_creada_con_su_fecha(self):
        ev = desde_registro_stream(_registro("INSERT", _meta()))
        self.assertEqual(ev["tipo"], "creada")
        self.assertEqual(ev["ts"], "2026-11-10T10:00:00+00:00")
        self.assertIsNone(ev["estado_anterior"])
        self.assertEqual((ev["id_categoria"], ev["id_zona"], ev["id_urgencia"]), (3, 21, 2))

    def test_transiciones_del_flujo(self):
        casos = [
            ("PENDIENTE", "ASIGNADO", "aceptar"),
            ("ASIGNADO", "EN_PROGRESO", "iniciar"),
            ("EN_PROGRESO", "RESUELTO", "resolver"),
            ("ASIGNADO", "PENDIENTE", "liberar"),
            ("EN_PROGRESO", "PENDIENTE", "liberar"),
            ("PENDIENTE", "CANCELADO", "cancelar"),
            ("EN_PROGRESO", "CANCELADO", "cancelar"),
        ]
        for antes, despues, tipo in casos:
            with self.subTest(antes=antes, despues=despues):
                nueva = _con_profesional(
                    estado={"S": despues},
                    fecha_actualizacion={"S": "2026-11-10T12:00:00+00:00"},
                )
                ev = desde_registro_stream(_registro("MODIFY", nueva, _con_profesional(estado={"S": antes})))
                self.assertEqual(ev["tipo"], tipo)
                self.assertEqual(ev["ts"], "2026-11-10T12:00:00+00:00")
                self.assertEqual((ev["estado_anterior"], ev["estado_nuevo"]), (antes, despues))

    def test_liberar_guarda_quien_solto_el_trabajo(self):
        # Al liberar, flujo hace REMOVE id_profesional: solo queda en la imagen vieja
        vieja = _con_profesional(estado={"S": "ASIGNADO"})
        ev = desde_registro_stream(_registro("MODIFY", _meta(), vieja))
        self.assertEqual(ev["tipo"], "liberar")
        self.assertEqual(ev["id_profesional"], "sub-pro")

    def test_calificacion_es_evento_con_puntuacion(self):
        vieja = _con_profesional(estado={"S": "RESUELTO"})
        calificacion = {"M": {
            "puntuacion": {"N": "4"},
            "fecha_calificacion": {"S": "2026-11-11T09:00:00+00:00"},
        }}
        nueva = _con_profesional(estado={"S": "RESUELTO"}, calificacion=calificacion)
        ev = desde_registro_stream(_registro("MODIFY", nueva, vieja))
        self.assertEqual(ev["tipo"], "calificada")
        self.assertEqual(ev["puntuacion"], 4)
        self.assertEqual(ev["ts"], "2026-11-11T09:00:00+00:00")

    def test_una_foto_nueva_no_es_evento(self):
        nueva = _meta(fotos={"M": {"f1": {"M": {"s3_key": {"S": "solicitudes/01JABC/f1"}}}}})
        self.assertIsNone(desde_registro_stream(_registro("MODIFY", nueva, _meta())))

    def test_sin_fecha_usa_la_del_stream(self):
        nueva = _con_profesional(estado={"S": "ASIGNADO"})
        del nueva["fecha_actualizacion"]
        ev = desde_registro_stream(_registro("MODIFY", nueva, _meta()))
        self.assertTrue(ev["ts"].startswith("2026-"))


class Deserializar(unittest.TestCase):
    def test_tipos(self):
        imagen = {
            "s": {"S": "x"},
            "entero": {"N": "7"},
            "decimal": {"N": "-34.6037"},
            "b": {"BOOL": True},
            "nulo": {"NULL": True},
            "lista": {"L": [{"S": "a"}, {"N": "1"}]},
            "numeros": {"NS": ["1", "25"]},
            "mapa": {"M": {"k": {"S": "v"}}},
        }
        self.assertEqual(deserializar(imagen), {
            "s": "x", "entero": 7, "decimal": -34.6037, "b": True, "nulo": None,
            "lista": ["a", 1], "numeros": [1, 25], "mapa": {"k": "v"},
        })


if __name__ == "__main__":
    unittest.main()
