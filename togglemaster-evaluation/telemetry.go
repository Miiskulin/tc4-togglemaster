package main

import (
	"context"
	"errors"
	"log"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// initTelemetry prepara os provedores de trace e de metrica e devolve
// a funcao de desligamento.
//
// Go nao tem equivalente ao `opentelemetry-instrument` do Python: nao
// existe auto-instrumentacao por wrapper de processo, porque o binario
// e compilado. Tudo aqui e explicito.
//
// Nenhum endereco esta no codigo. Os exportadores leem a configuracao
// das variaveis OTEL_EXPORTER_OTLP_ENDPOINT e OTEL_EXPORTER_OTLP_PROTOCOL,
// definidas no manifesto do Kubernetes. O mesmo vale para o nome do
// servico: resource.Default(), usado por padrao pelos provedores, ja
// inclui o detector de ambiente, que le OTEL_SERVICE_NAME e
// OTEL_RESOURCE_ATTRIBUTES.
func initTelemetry(ctx context.Context) (func(context.Context) error, error) {
	// ---------------------------------------------------------
	// Traces
	// ---------------------------------------------------------
	traceExporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}

	tracerProvider := sdktrace.NewTracerProvider(
		// WithBatcher agrupa spans antes de enviar. A alternativa,
		// WithSyncer, envia um a um e adiciona latencia a cada
		// requisicao - serve para teste, nao para producao.
		sdktrace.WithBatcher(
			traceExporter,
			sdktrace.WithBatchTimeout(5*time.Second),
		),
	)
	otel.SetTracerProvider(tracerProvider)

	// ---------------------------------------------------------
	// Propagacao de contexto
	// ---------------------------------------------------------
	// Sem isto, cada servico gera um trace solto e o Service Map do
	// APM nao liga um ao outro. O TraceContext implementa o cabecalho
	// `traceparent` do padrao W3C, que e o mesmo que a instrumentacao
	// automatica do Python usa - e por isso que Go e Python conversam.
	otel.SetTextMapPropagator(
		propagation.NewCompositeTextMapPropagator(
			propagation.TraceContext{},
			propagation.Baggage{},
		),
	)

	// ---------------------------------------------------------
	// Metricas
	// ---------------------------------------------------------
	// O otelhttp publica http.server.request.duration automaticamente
	// quando ha um MeterProvider registrado. E dessa metrica que saem
	// o painel de taxa de requisicoes e o alerta de erro 5xx.
	metricExporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		// Trace ja esta de pe; derrubar tudo por causa da metrica
		// seria pior que seguir sem ela.
		_ = tracerProvider.Shutdown(ctx)
		return nil, err
	}

	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(
			sdkmetric.NewPeriodicReader(
				metricExporter,
				sdkmetric.WithInterval(15*time.Second),
			),
		),
	)
	otel.SetMeterProvider(meterProvider)

	log.Println("OpenTelemetry inicializado")

	shutdown := func(ctx context.Context) error {
		return errors.Join(
			tracerProvider.Shutdown(ctx),
			meterProvider.Shutdown(ctx),
		)
	}

	return shutdown, nil
}
