FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .

# opentelemetry-bootstrap detecta as bibliotecas instaladas (Flask,
# psycopg2, requests, boto3) e instala a instrumentacao de cada uma.
RUN pip install --no-cache-dir -r requirements.txt \
    && opentelemetry-bootstrap -a install

COPY . .

EXPOSE 8005

CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8005", "app:app"]
