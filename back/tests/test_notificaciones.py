"""Tests de barriofix.notificaciones: que se avisa y a quien.

    PYTHONPATH=back/layers/common/python python -m unittest discover -s back/tests
"""

import unittest

from barriofix.notificaciones import armar

PRO = {"M": {"id_usuario": {"S": "sub-pro"}, "nombre": {"S": "Diego"}, "apellido": {"S": "Martínez"}}}


def _meta(estado, con_pro=True, **extra):
    m = {
        "id_solicitud": {"S": "S1"}, "titulo": {"S": "Pierde agua la canilla"},
        "estado": {"S": estado}, "id_cliente": {"S": "sub-cliente"},
        "fecha_actualizacion": {"S": "2026-11-10T12:00:00+00:00"},
    }
    if con_pro:
        m["id_profesional"] = {"S": "sub-pro"}
        m["profesional"] = PRO
    m.update(extra)
    return m


def _cambio(antes, despues, pro_antes=True, pro_despues=True):
    return {"eventID": "e", "eventName": "MODIFY", "dynamodb": {
        "OldImage": _meta(antes, pro_antes), "NewImage": _meta(despues, pro_despues)}}


class Armar(unittest.TestCase):
    def test_avisos_al_cliente(self):
        casos = [
            (_cambio("PENDIENTE", "ASIGNADO", pro_antes=False), "Diego Martínez tomó tu solicitud"),
            (_cambio("ASIGNADO", "EN_PROGRESO"), "Diego Martínez empezó el trabajo"),
            (_cambio("EN_PROGRESO", "RESUELTO"), "Tu solicitud quedó resuelta"),
        ]
        for registro, asunto in casos:
            with self.subTest(asunto=asunto):
                aviso = armar(registro)
                self.assertEqual(aviso["destinatario"], "sub-cliente")
                self.assertEqual(aviso["asunto"], asunto)
                self.assertIn("Pierde agua la canilla", aviso["cuerpo"])

    def test_liberar_avisa_al_cliente_con_el_nombre_del_que_solto(self):
        aviso = armar(_cambio("ASIGNADO", "PENDIENTE", pro_despues=False))
        self.assertEqual(aviso["destinatario"], "sub-cliente")
        self.assertIn("Diego Martínez no va a poder", aviso["cuerpo"])

    def test_cancelar_avisa_al_profesional_asignado(self):
        aviso = armar(_cambio("ASIGNADO", "CANCELADO"))
        self.assertEqual(aviso["destinatario"], "sub-pro")

    def test_cancelar_sin_profesional_no_avisa_a_nadie(self):
        self.assertIsNone(armar(_cambio("PENDIENTE", "CANCELADO", pro_antes=False, pro_despues=False)))

    def test_creacion_calificacion_y_fotos_no_se_avisan(self):
        creada = {"eventID": "e", "eventName": "INSERT", "dynamodb": {"NewImage": _meta("PENDIENTE", False)}}
        calificada = {"eventID": "e", "eventName": "MODIFY", "dynamodb": {
            "OldImage": _meta("RESUELTO"),
            "NewImage": _meta("RESUELTO", calificacion={"M": {"puntuacion": {"N": "5"}}})}}
        foto = {"eventID": "e", "eventName": "MODIFY", "dynamodb": {
            "OldImage": _meta("ASIGNADO"), "NewImage": _meta("ASIGNADO", fotos={"M": {}})}}
        for registro in (creada, calificada, foto):
            self.assertIsNone(armar(registro))


if __name__ == "__main__":
    unittest.main()
