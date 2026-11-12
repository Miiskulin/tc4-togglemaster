package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/extra/redisotel/v9"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// App struct para injeção de dependência
type App struct {
	// Broken e lido em toda requisicao e escrito pelo endpoint de
	// injecao. atomic.Bool porque o servidor HTTP atende em
	// varias goroutines - um bool simples seria corrida de dados.
	Broken atomic.Bool

	RedisClient         *redis.Client
	SqsSvc              *sqs.SQS
	SqsQueueURL         string
	HttpClient          *http.Client
	FlagServiceURL      string
	TargetingServiceURL string
}

func main() {
	_ = godotenv.Load() // Carrega .env para dev local

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		log.Fatal("REDIS_URL deve ser definida (ex: redis://localhost:6379)")
	}

	flagSvcURL := os.Getenv("FLAG_SERVICE_URL")
	if flagSvcURL == "" {
		log.Fatal("FLAG_SERVICE_URL deve ser definida")
	}

	targetingSvcURL := os.Getenv("TARGETING_SERVICE_URL")
	if targetingSvcURL == "" {
		log.Fatal("TARGETING_SERVICE_URL deve ser definida")
	}

	// SQS é opcional no dev local, mas obrigatório em prod
	sqsQueueURL := os.Getenv("AWS_SQS_URL")
	awsRegion := os.Getenv("AWS_REGION")
	if sqsQueueURL == "" {
		log.Println("Atenção: AWS_SQS_URL não definida. Eventos não serão enviados.")
	}
	if awsRegion == "" && sqsQueueURL != "" {
		log.Fatal("AWS_REGION deve ser definida para usar SQS")
	}

	// --- OpenTelemetry ---
	ctx := context.Background()

	shutdownTelemetry, err := initTelemetry(ctx)
	if err != nil {
		// Telemetria quebrada não derruba o serviço: uma queda do
		// Collector viraria queda da aplicação, o oposto do que
		// observabilidade deve produzir.
		log.Printf("OpenTelemetry não inicializou, seguindo sem telemetria: %v", err)
		shutdownTelemetry = func(context.Context) error { return nil }
	}

	defer func() {
		ctxShutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		if err := shutdownTelemetry(ctxShutdown); err != nil {
			log.Printf("Erro ao encerrar a telemetria: %v", err)
		}
	}()

	// --- Inicializa Clientes ---

	// Cliente Redis
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Fatalf("Não foi possível parsear a URL do Redis: %v", err)
	}
	rdb := redis.NewClient(opt)

	// Um span por comando Redis, filho do span da requisição. É o que
	// mostra no trace se a resposta veio do cache ou do banco — a
	// diferença entre 2ms e 200ms neste serviço.
	if err := redisotel.InstrumentTracing(rdb); err != nil {
		log.Printf("Não foi possível instrumentar o Redis: %v", err)
	}

	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("Não foi possível conectar ao Redis: %v", err)
	}
	log.Println("Conectado ao Redis com sucesso!")

	// Cliente SQS (AWS SDK)
	var sqsSvc *sqs.SQS
	if sqsQueueURL != "" {
		sess, err := session.NewSession(&aws.Config{Region: aws.String(awsRegion)})
		if err != nil {
			log.Fatalf("Não foi possível criar sessão AWS: %v", err)
		}
		sqsSvc = sqs.New(sess)
		log.Println("Cliente SQS inicializado com sucesso.")
	}

	// Cliente HTTP (com timeout)
	//
	// O Transport instrumentado é a peça que INJETA o cabeçalho
	// traceparent nas chamadas ao flag-service e ao targeting-service.
	// Sem ele, cada serviço abriria um trace próprio e o Service Map
	// mostraria cinco ilhas em vez de um grafo de dependências.
	httpClient := &http.Client{
		Timeout:   5 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}

	// Cria a instância da App
	app := &App{
		RedisClient:         rdb,
		SqsSvc:              sqsSvc,
		SqsQueueURL:         sqsQueueURL,
		HttpClient:          httpClient,
		FlagServiceURL:      flagSvcURL,
		TargetingServiceURL: targetingSvcURL,
	}

	// --- Rotas ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/evaluate", app.evaluationHandler)

	// Rotas de injecao de falha, so quando habilitadas por
	// variavel de ambiente. Sem ela, nao existem.
	if debugBreakEnabled() {
		mux.HandleFunc("/debug/break", app.breakHandler)
		mux.HandleFunc("/debug/heal", app.healHandler)
		log.Println("ATENCAO: /debug/break habilitado - apenas para demonstracao")
	}
	log.Println("Servico de Avaliacao iniciado")

	// Lado servidor: cria o span raiz e lê o traceparent de quem
	// chamou, se houver.
	handler := otelhttp.NewHandler(
		mux,
		"evaluation-service",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
