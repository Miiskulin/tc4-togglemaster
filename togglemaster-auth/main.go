package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/XSAM/otelsql"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// App struct (para injeção de dependência)
type App struct {
	DB        *sql.DB
	MasterKey string
}

func main() {
	// Carrega o .env para desenvolvimento local.
	// Em produção, as variáveis são fornecidas pelo ambiente.
	_ = godotenv.Load()

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8001"
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL deve ser definida")
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		log.Fatal("MASTER_KEY deve ser definida")
	}

	// --- OpenTelemetry ---
	// Antes da conexão com o banco: o otelsql precisa que o provedor
	// de traces já esteja registrado no momento em que abre o pool.
	ctx := context.Background()

	shutdownTelemetry, err := initTelemetry(ctx)
	if err != nil {
		// Telemetria quebrada não pode derrubar o serviço. Sem isso,
		// uma indisponibilidade do Collector viraria indisponibilidade
		// da aplicação — o oposto do que observabilidade deve fazer.
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

	// --- Conexão com o Banco ---
	db, err := connectDB(databaseURL)
	if err != nil {
		log.Fatalf("Não foi possível conectar ao banco de dados: %v", err)
	}
	defer db.Close()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/validate", app.validateKeyHandler)
	mux.Handle(
		"/admin/keys",
		app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler)),
	)

	// otelhttp cria o span raiz de cada requisição e, igualmente
	// importante, LÊ o cabeçalho traceparent de quem chamou. É isso
	// que faz o trace do evaluation-service continuar aqui dentro em
	// vez de começar um novo.
	//
	// O formatador de nome existe porque, sem ele, todos os spans se
	// chamariam "auth-service" e o APM não distinguiria /validate de
	// /admin/keys.
	handler := otelhttp.NewHandler(
		mux,
		"auth-service",
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

	log.Println("Serviço de Autenticação iniciado")

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("Falha ao iniciar servidor HTTP: %v", err)
	}
}

// connectDB inicializa e testa a conexão com o PostgreSQL.
//
// otelsql.Open no lugar de sql.Open: ele embrulha o driver e cria um
// span para cada query, filho do span da requisição HTTP. É o que
// permite abrir um trace no APM e ver quanto tempo foi gasto no banco,
// em vez de apenas "o serviço demorou".
func connectDB(databaseURL string) (*sql.DB, error) {
	db, err := otelsql.Open("pgx", databaseURL,
		otelsql.WithAttributes(semconv.DBSystemPostgreSQL),
	)
	if err != nil {
		return nil, err
	}

	if err = db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}

	log.Println("Conectado ao PostgreSQL com sucesso")
	return db, nil
}
