"""Tests del matching: items de membresia y deteccion de trabajos disponibles.

    PYTHONPATH=back/layers/common/python python -m unittest discover -s back/tests
"""

import unittest

from barriofix import membresias
from barriofix.notificaciones import aviso_oportunidad, oportunidad

PERFIL_PRO = {"rol": "PROFESIONAL", "nombre": "Diego", "apellido": "Martínez", "email": "d@example.com",
              "disponible": True, "categorias": {25, 1}, "zonas": {21, 5}}


class Membresias(unittest.TestCase):
    def test_un_item_por_categoria_con_la_clave_del_gsi(self):
        items = membresias.items("sub-pro", PERFIL_PRO)
        self.assertEqual([i["SK"] for i in items], ["PROCAT#0001", "PROCAT#0025"])
        self.assertEqual([i["pro_categoria"] for i in items], [1, 25])
        for i in items:
            self.assertEqual(i["PK"], "USER#sub-pro")
            self.assertEqual(i["zonas"], {21, 5})
            self.assertEqual((i["email"], i["disponible"]), ("d@example.com", True))

    def test_sin_zonas_no_lleva_el_set(self):
        # DynamoDB rechaza sets vacios
        items = membresias.items("sub-pro", {**PERFIL_PRO, "zonas": set()})
        self.assertTrue(items and all("zonas" not in i for i in items))

    def test_un_cliente_no_tiene_membresias(self):
        self.assertEqual(membresias.items("sub-cli", {"rol": "CLIENTE", "nombre": "J", "apellido": "P"}), [])


def _meta(estado, pro=False):
    m = {"id_solicitud": {"S": "S1"}, "titulo": {"S": "Pierde la canilla"}, "estado": {"S": estado},
         "id_categoria": {"N": "1"}, "id_zona": {"N": "21"}, "id_urgencia": {"N": "3"},
         "id_cliente": {"S": "sub-cli"}, "fecha_creacion": {"S": "2026-11-10T10:00:00+00:00"},
         "fecha_actualizacion": {"S": "2026-11-10T12:00:00+00:00"}}
    if pro:
        m["id_profesional"] = {"S": "sub-pro"}
    return m


class Oportunidad(unittest.TestCase):
    def test_solicitud_nueva(self):
        op = oportunidad({"eventID": "e", "eventName": "INSERT", "dynamodb": {"NewImage": _meta("PENDIENTE")}})
        self.assertEqual((op["id_categoria"], op["id_zona"], op["id_urgencia"]), (1, 21, 3))
        self.assertFalse(op["liberada"])
        self.assertIsNone(op["excluir"])

    def test_liberada_excluye_al_que_la_solto(self):
        op = oportunidad({"eventID": "e", "eventName": "MODIFY",
                          "dynamodb": {"OldImage": _meta("ASIGNADO", pro=True), "NewImage": _meta("PENDIENTE")}})
        self.assertTrue(op["liberada"])
        self.assertEqual(op["excluir"], "sub-pro")

    def test_otros_cambios_no_son_oportunidad(self):
        aceptada = {"eventID": "e", "eventName": "MODIFY",
                    "dynamodb": {"OldImage": _meta("PENDIENTE"), "NewImage": _meta("ASIGNADO", pro=True)}}
        foto = {"eventID": "e", "eventName": "MODIFY",
                "dynamodb": {"OldImage": _meta("PENDIENTE"), "NewImage": {**_meta("PENDIENTE"), "fotos": {"M": {}}}}}
        self.assertIsNone(oportunidad(aceptada))
        self.assertIsNone(oportunidad(foto))

    def test_texto_del_aviso(self):
        op = oportunidad({"eventID": "e", "eventName": "INSERT", "dynamodb": {"NewImage": _meta("PENDIENTE")}})
        aviso = aviso_oportunidad(op, categoria="Plomería", zona="Palermo", urgencia="Alta")
        self.assertEqual(aviso["asunto"], "Nuevo trabajo de Plomería en Palermo")
        self.assertIn("\"Pierde la canilla\" (urgencia alta)", aviso["cuerpo"])


if __name__ == "__main__":
    unittest.main()
