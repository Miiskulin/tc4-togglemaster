# Imagem base com Python
FROM python:3.11-slim

# Diretório de trabalho dentro do container
WORKDIR /app

# Copia as dependências primeiro
COPY requirements.txt .

# Instala as dependências
# opentelemetry-bootstrap detecta as bibliotecas instaladas (Flask,
# psycopg2, requests, boto3) e instala a instrumentacao de cada uma.
RUN pip install --no-cache-dir -r requirements.txt \
    && opentelemetry-bootstrap -a install

# Copia o código da aplicação
COPY . .

# Porta utilizada pelo flag-service
EXPOSE 8002

# Inicia a aplicação com Gunicorn
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
