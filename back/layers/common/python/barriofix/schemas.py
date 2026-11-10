"""Modelos de entrada (Pydantic v2). Powertools los valida con enable_validation.

Las salidas se arman como dicts en serializers.py, respetando el contrato que ya
consume el front.
"""

from typing import List, Literal, Optional

from pydantic import BaseModel, Field, model_validator


class RegistroIn(BaseModel):
    nombre: str = Field(min_length=1, max_length=100)
    apellido: str = Field(min_length=1, max_length=100)
    telefono: Optional[str] = Field(default=None, max_length=30)
    rol: Literal["CLIENTE", "PROFESIONAL"] = "CLIENTE"
    descripcion_profesional: Optional[str] = None
    categorias: List[int] = Field(default_factory=list, max_length=40)
    # Zonas que cubre el profesional; sin zonas no recibe avisos de trabajos nuevos
    zonas: List[int] = Field(default_factory=list, max_length=100)


class SolicitudIn(BaseModel):
    titulo: str = Field(min_length=1, max_length=150)
    descripcion: str = Field(min_length=1)
    direccion: str = Field(min_length=1, max_length=255)
    id_categoria: int
    id_urgencia: int
    id_zona: int
    # Pin opcional del mapa. Van juntas o ninguna
    lat: Optional[float] = Field(default=None, ge=-90, le=90)
    lng: Optional[float] = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def _ubicacion_completa(self):
        if (self.lat is None) != (self.lng is None):
            raise ValueError("lat y lng van juntas")
        return self


class TransicionIn(BaseModel):
    motivo: Optional[str] = None


class CalificacionIn(BaseModel):
    puntuacion: int = Field(ge=1, le=5)
    comentario: Optional[str] = None
