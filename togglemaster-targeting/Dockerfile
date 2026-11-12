# Etapa 1: imagem base
FROM python:3.11-slim

WORKDIR /app

# Instala dependências Python
COPY requirements.txt .

# opentelemetry-bootstrap detecta as bibliotecas instaladas (Flask,
# psycopg2, requests, boto3) e instala a instrumentacao de cada uma.
RUN pip install --no-cache-dir -r requirements.txt \
    && opentelemetry-bootstrap -a install

# Copia o código da aplicação
COPY . .

EXPOSE 8003

# Executa com Gunicorn
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8003", "app:app"]
