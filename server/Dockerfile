# Stage 1: pega só o binário do node de uma imagem pequena
FROM node:20-slim AS node_base

# Stage 2: imagem final com Python + ffmpeg + node binary copiado
FROM python:3.12-slim
WORKDIR /app

# Copia apenas os binários necessários do node (sem instalar 850MB de deps)
COPY --from=node_base /usr/local/bin/node /usr/local/bin/node

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 3004
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3004"]
