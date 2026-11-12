package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

// sqsCarrier adapta os MessageAttributes do SQS à interface TextMapCarrier
// do OpenTelemetry.
//
// Em HTTP isso vem pronto: propagation.HeaderCarrier embrulha
// http.Header e o otelhttp cuida do resto. Numa fila não existe
// cabeçalho, então o contexto precisa viajar em algum campo da
// mensagem. No SQS esse campo são os MessageAttributes.
//
// Sem isto, o trace termina no evaluation-service e o analytics-service
// começa um novo. Os dois apareceriam no APM como serviços
// desconectados, e o mapa de dependências ficaria incompleto.
type sqsCarrier map[string]*sqs.MessageAttributeValue

func (c sqsCarrier) Get(key string) string {
	v, ok := c[key]
	if !ok || v == nil || v.StringValue == nil {
		return ""
	}
	return *v.StringValue
}

func (c sqsCarrier) Set(key, value string) {
	c[key] = &sqs.MessageAttributeValue{
		DataType:    aws.String("String"),
		StringValue: aws.String(value),
	}
}

func (c sqsCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}

func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		log.Println("[SQS_DISABLED] Evento de avaliacao nao enviado")
		return
	}

	// O aws-sdk-go v1 não tem instrumentação oficial do OpenTelemetry
	// (só o v2 tem, via otelaws). Por isso o span é criado à mão.
	//
	// SpanKindProducer é o que diz ao APM que isto é a ponta de
	// escrita de uma fila, e não uma chamada síncrona qualquer.
	tracer := otel.Tracer("togglemaster/evaluation/sqs")

	ctx, span := tracer.Start(ctx, "togglemaster-analytics send",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.operation", "publish"),
			attribute.String("messaging.destination.name", "togglemaster-analytics"),
		),
	)
	defer span.End()

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "falha ao serializar o evento")
		log.Printf("Erro ao serializar evento SQS: %v", err)
		return
	}

	// Injeta traceparent (e tracestate) nos atributos da mensagem.
	// O propagador é o mesmo registrado em telemetry.go, então o
	// formato é o W3C Trace Context — idêntico ao que o Python do
	// analytics-service entende.
	carrier := sqsCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)

	_, err = a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: carrier,
	})

	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "falha ao enviar para o SQS")
		log.Printf("Erro ao enviar mensagem para SQS: %v", err)
		return
	}

	log.Println("Evento de avaliacao enviado para SQS")
}

// garante em tempo de compilação que sqsCarrier satisfaz a interface
var _ propagation.TextMapCarrier = sqsCarrier{}
