"""Genera el historico de solicitudes de demo (mock data) para analytics.

    python back/scripts/generar_seed_historico.py

Escribe terraform/organization/seed/solicitudes_historicas.json, con la misma
forma que seed/solicitudes.json. Terraform carga las dos en DynamoDB y deriva de
ellas los eventos de analytics, asi la app y Athena muestran los mismos datos.

Es determinista (semilla fija): correrlo dos veces da el mismo archivo. Las
solicitudes estan armadas para que cada consulta de negocio cuente algo:

- Zonas del sur (Villa Lugano, Mataderos, Villa Soldati) desatendidas: tardan
  dias en tomarse o nadie las toma, y ahi se concentran las cancelaciones.
- Gas tiene un solo profesional (Mariano): es lento en todos lados y depende de
  una persona (concentracion de oferta).
- Federico acepta y suelta seguido (flakiness); en aire acondicionado lo
  rescata Mariano, en sus otras categorias nadie.
- Cerrajeria y carpinteria no las cubre nadie.
- La mitad de las solicitudes se marca urgente y eso casi no acelera nada.
- De noche se toma todo mas tarde.
- Los clientes del norte vuelven a pedir; los del sur pidieron al principio y
  despues dejaron de usar la app (retencion por cohorte).
"""

import json
import math
import random
from pathlib import Path

SALIDA = Path(__file__).resolve().parents[2] / "terraform/organization/seed/solicitudes_historicas.json"
rng = random.Random(2026)

# usuarios de demo (locals.tf)
NOMBRES = {
    "carlos.electricista": "Carlos Gómez",
    "diego.plomero": "Diego Martínez",
    "mariano.gasista": "Mariano Rodríguez",
    "pablo.pintor": "Pablo Sánchez",
    "federico.tecnico": "Federico Torres",
}
CATEGORIAS_PRO = {
    "carlos.electricista": {2, 17, 30},
    "diego.plomero": {1, 25},
    "mariano.gasista": {3, 4},
    "pablo.pintor": {7, 8, 10, 25},
    "federico.tecnico": {4, 14, 15, 16},
}
FLAKY = "federico.tecnico"

# cliente -> (zonas donde vive, cantidad de pedidos, rango de dias atras)
# Los del norte piden durante todo el periodo; los del sur solo al principio
CLIENTES = {
    "juan.perez": ([21, 36], 17, (12, 60)),
    "sofia.garcia": ([5, 20], 15, (12, 60)),
    "martin.lopez": ([8, 28], 13, (12, 60)),
    "valentina.romero": ([40, 16], 8, (34, 60)),
    "lucas.fernandez": ([47, 16], 7, (36, 60)),
}
CLIENTA = {"sofia.garcia", "valentina.romero"}
DESIERTOS = {40, 16, 47}
BARRIO = {21: "Palermo", 36: "Villa Crespo", 5: "Belgrano", 20: "Núñez", 8: "Caballito",
          28: "Recoleta", 40: "Villa Lugano", 16: "Mataderos", 47: "Villa Soldati"}
CALLES = {
    21: ["Honduras", "Thames", "Gurruchaga", "Av. Santa Fe"], 36: ["Malabia", "Thames", "Av. Corrientes"],
    5: ["Echeverría", "Av. Cabildo", "Mendoza"], 20: ["Av. del Libertador", "Manuela Pedraza", "Crisólogo Larralde"],
    8: ["Av. Rivadavia", "Rosario", "José Bonifacio"], 28: ["Av. Callao", "Junín", "Peña"],
    40: ["Av. Riestra", "Murguiondo", "Cosquín"], 16: ["Av. Directorio", "Lisandro de la Torre", "Tandil"],
    47: ["Av. Mariano Acosta", "Lafuente", "Av. Castañares"],
}

# categoria -> (peso en la demanda, [(titulo, descripcion)])
DEMANDA = {
    1: (14, [("Pierde agua el flexible del lavatorio", "Gotea la conexión del lavatorio y moja el mueble de abajo."),
             ("Inodoro que no deja de cargar", "El depósito sigue cargando agua todo el tiempo, se escucha a la noche."),
             ("Canilla de la cocina que gotea", "La canilla monocomando gotea aunque esté bien cerrada.")]),
    2: (12, [("Salta la térmica del baño", "Cuando se prende la estufa del baño salta la térmica."),
             ("Tomacorriente quemado en el living", "Un toma quedó negro y no anda, huele a quemado."),
             ("Instalar luces en el pasillo", "Quiero poner dos apliques nuevos en el pasillo.")]),
    3: (10, [("Calefón que se apaga solo", "El calefón prende y a los pocos minutos se apaga."),
             ("Olor a gas en la cocina", "Hay olor a gas cerca de la cocina, cerramos la llave por las dudas."),
             ("Revisión de estufa a gas", "Antes del invierno quiero que revisen la estufa del living.")]),
    4: (12, [("Aire acondicionado que gotea adentro", "El split gotea agua por la unidad interior."),
             ("El aire no enfría", "Prende y tira aire pero no enfría nada."),
             ("Service de aire acondicionado", "Limpieza y carga de gas del split del dormitorio.")]),
    7: (8, [("Pintar un dormitorio", "Dormitorio de 3x3, paredes y techo."),
            ("Retocar paredes del pasillo", "Quedaron marcas y algunas manchas después de una mudanza.")]),
    25: (7, [("Mancha de humedad en el techo del baño", "Apareció una mancha que crece después de cada lluvia."),
             ("Pared con salitre en el comedor", "La pared de abajo tiene salitre y la pintura se descascara.")]),
    14: (8, [("El lavarropas no centrifuga", "Lava pero en el centrifugado se frena y queda la ropa empapada."),
             ("Heladera que no enfría abajo", "El freezer anda pero la parte de abajo está tibia.")]),
    15: (5, [("Internet se corta en el escritorio", "El wifi no llega bien al escritorio y se corta todo el tiempo."),
             ("Configurar router nuevo", "Cambiamos de proveedor y hay que configurar el router.")]),
    5: (4, [("Me quedé afuera", "Se rompió la llave dentro de la cerradura de la puerta de entrada."),
            ("Cambiar cerradura de la puerta", "Quiero cambiar la cerradura por una de seguridad.")]),
    12: (3, [("Puerta del placard descolgada", "Se salió una bisagra y la puerta quedó colgando."),
             ("Ajustar puertas de la alacena", "Las puertas de la alacena no cierran bien.")]),
}
COMENTARIOS = {
    5: ["Impecable, rápido y muy prolijo.", "Excelente, lo recomiendo.", "Resolvió todo en una visita."],
    4: ["Buen trabajo, tardó un poco en venir.", "Bien resuelto, aunque costó coordinar el horario."],
    3: ["Lo resolvió, pero tuve que esperar bastante.", "Cumplió, nada más."],
    2: ["Tardó muchísimo y tuve que insistir.", "Quedó a medias la primera vez."],
}


def horas(lo, hi):
    return rng.uniform(lo, hi)


def tiempo_hasta_aceptar(zona, cat, urgencia, nocturna):
    """Horas hasta que alguien acepta, o None si nadie la toma."""
    if zona in DESIERTOS:
        if rng.random() < 0.45:
            return None
        h = horas(18, 60)
    else:
        h = horas(0.5, 4)
    if cat == 3:
        h *= 2.5  # un solo gasista para toda la ciudad
    if nocturna:
        h += horas(6, 10)
    # La urgencia casi no cambia nada: la mitad de las solicitudes se marca urgente
    h *= {3: 0.9, 2: 1.0, 1: 1.1}[urgencia]
    return h


def generar():
    pedidos = []
    for cliente, (zonas, cantidad, (dmin, dmax)) in CLIENTES.items():
        for _ in range(cantidad):
            pedidos.append((cliente, rng.choice(zonas), rng.randint(dmin, dmax), rng.randint(0, 23)))
    # Mas viejas primero: el id crece con la fecha, como un ULID
    pedidos.sort(key=lambda p: (-p[2], p[3]))

    cats = list(DEMANDA)
    pesos = [DEMANDA[c][0] for c in cats]
    salida = []
    for n, (cliente, zona, dias, hora) in enumerate(pedidos, start=1):
        cat = rng.choices(cats, weights=pesos)[0]
        urgencia = rng.choices([3, 2, 1], weights=[50, 30, 20])[0]
        nocturna = hora >= 22 or hora < 7
        titulo, descripcion = rng.choice(DEMANDA[cat][1])
        nombre_cliente = "La cliente" if cliente in CLIENTA else "El cliente"

        seg = [paso("PENDIENTE", cliente, None, 0, "Solicitud publicada por el cliente")]
        t = 0.0
        profesional = None
        calificacion = None
        candidatos = [p for p, cs in CATEGORIAS_PRO.items() if cat in cs]
        tta = tiempo_hasta_aceptar(zona, cat, urgencia, nocturna) if candidatos else None

        if tta is None:
            # Nadie la tomo: casi siempre el cliente termina cancelando
            if rng.random() < 0.75:
                t = horas(18, 72)
                seg.append(paso("CANCELADO", cliente, None, t, f"{nombre_cliente} canceló la solicitud: nadie la tomó"))
        else:
            # Federico se queda con la mayoria de los aires (y despues los suelta)
            if cat == 4:
                pro = FLAKY if rng.random() < 0.6 else "mariano.gasista"
            else:
                pro = rng.choice(candidatos)
            t = tta
            seg.append(paso("ASIGNADO", pro, pro, t, f"{NOMBRES[pro]} aceptó la solicitud"))

            if rng.random() < (0.45 if pro == FLAKY else 0.04):
                t += horas(3, 20)
                seg.append(paso("PENDIENTE", pro, None, t,
                                f"{NOMBRES[pro]} canceló la asignación. La solicitud vuelve a estar disponible"))
                otros = [p for p in candidatos if p != pro]
                if otros:
                    pro = rng.choice(otros)
                    t += horas(2, 30)
                    seg.append(paso("ASIGNADO", pro, pro, t, f"{NOMBRES[pro]} aceptó la solicitud"))
                else:
                    t += horas(10, 30)
                    seg.append(paso("CANCELADO", cliente, None, t,
                                    f"{nombre_cliente} canceló la solicitud: el profesional la soltó"))
                    pro = None

            if pro is not None and rng.random() < 0.05:
                # Aceptada pero el profesional no aparece: el cliente se cansa
                t += horas(24, 48)
                seg.append(paso("CANCELADO", cliente, None, t,
                                f"{nombre_cliente} canceló la solicitud: el profesional no vino"))
                profesional = pro
            elif pro is not None:
                profesional = pro
                t += horas(4, 30)
                seg.append(paso("EN_PROGRESO", pro, pro, t, "El profesional comenzó el trabajo"))
                t += horas(4, 48)
                seg.append(paso("RESUELTO", pro, pro, t, "Trabajo terminado"))
                if rng.random() < 0.75:
                    estrellas = 5 - (tta > 24) - (pro == FLAKY) - (t > 96)
                    estrellas = max(2, estrellas - (rng.random() < 0.15))
                    t_cal = t + horas(2, 30)
                    calificacion = {
                        "puntuacion": estrellas,
                        "comentario": rng.choice(COMENTARIOS[estrellas]),
                        "offset_horas": math.ceil(t_cal),
                    }

        # Los offsets van en horas enteras y estrictamente crecientes
        ultimo = 0
        for s in seg[1:]:
            s["offset_horas"] = max(math.ceil(s["offset_horas"]), ultimo + 1)
            ultimo = s["offset_horas"]
        if calificacion:
            calificacion["offset_horas"] = max(calificacion["offset_horas"], ultimo + 1)
            ultimo = calificacion["offset_horas"]

        # Nada puede quedar en el futuro: si el ciclo es largo, la solicitud es mas vieja
        creada_hace = dias * 24 - hora
        while creada_hace <= ultimo:
            creada_hace += 24

        final = seg[-1]
        cancelada = final["estado"] == "CANCELADO"
        salida.append({
            "id": f"HIST{n:022d}",
            "cliente": cliente,
            "id_categoria": cat,
            "id_urgencia": urgencia,
            "id_zona": zona,
            "titulo": titulo,
            "descripcion": descripcion,
            "direccion": f"{rng.choice(CALLES[zona])} {rng.randint(100, 5900)}, {BARRIO[zona]}",
            "creada_hace_horas": creada_hace,
            "estado": final["estado"],
            # Al cancelar, la META conserva al profesional que estaba asignado
            "profesional": profesional if final["estado"] != "PENDIENTE" else None,
            "cancelada_por_cliente": cancelada,
            "cancelada_offset_horas": final["offset_horas"] if cancelada else None,
            "calificacion": calificacion,
            "seguimiento": seg,
        })
    return salida


def paso(estado, actor, profesional, offset, motivo):
    return {"estado": estado, "actor": actor, "profesional": profesional, "offset_horas": offset, "motivo": motivo}


if __name__ == "__main__":
    solicitudes = generar()
    SALIDA.write_text(json.dumps(solicitudes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(solicitudes)} solicitudes en {SALIDA}")
