package main

import (
	"log"
	"net/http"
	"os"

	"go.opentelemetry.io/otel/trace"
)

// Injecao de falha para demonstrar o ciclo de self-healing.
//
// POR QUE EXISTE
//
// O enunciado pede que a automacao de self-healing seja demonstrada
// reagindo a um alerta. Para isso a falha precisa de duas propriedades
// que uma falha real raramente tem juntas:
//
//  1. ser provocavel sob demanda, na hora da gravacao;
//  2. ser curada por `kubectl rollout restart`.
//
// Parar o banco do flag-service, que o enunciado cita como exemplo,
// satisfaz a primeira mas nao a segunda: reiniciar o evaluation nao
// religa um RDS. O ciclo ficaria incompleto - alerta dispara,
// automacao roda, servico continua quebrado.
//
// O estado aqui vive em memoria do processo. Reiniciar o pod cria um
// processo novo, com o estado zerado. E por isso que o rollout restart
// cura de verdade, e nao por encenacao.
//
// SEGURANCA
//
// O endpoint so e registrado quando DEBUG_BREAK_ENABLED=true. Em
// qualquer ambiente onde a variavel nao esteja definida, a rota
// responde 404 porque simplesmente nao existe - nao ha verificacao em
// tempo de requisicao que alguem possa contornar.

// debugBreakEnabled le a variavel uma vez, na inicializacao.
func debugBreakEnabled() bool {
	return os.Getenv("DEBUG_BREAK_ENABLED") == "true"
}

// breakHandler passa o servico para o modo de falha.
func (a *App) breakHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		http.Error(w, `{"error": "use POST"}`, http.StatusMethodNotAllowed)
		return
	}

	a.Broken.Store(true)

	// Marca o span atual para a injecao aparecer no trace do APM, e
	// nao so no log. Durante a demonstracao isso deixa visivel o
	// momento exato em que o servico foi quebrado.
	if span := trace.SpanFromContext(r.Context()); span.IsRecording() {
		span.AddEvent("falha injetada manualmente")
	}

	log.Println("[DEBUG_BREAK] Falha injetada: /evaluate passa a responder 500")

	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"falha injetada","efeito":"/evaluate responde 500 ate o pod reiniciar"}`))
}

// healHandler desfaz a injecao sem reiniciar o pod.
//
// Existe para ensaiar a demonstracao sem esperar um rollout, e como
// saida de emergencia se algo der errado durante a gravacao.
func (a *App) healHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		http.Error(w, `{"error": "use POST"}`, http.StatusMethodNotAllowed)
		return
	}

	a.Broken.Store(false)

	log.Println("[DEBUG_BREAK] Falha removida manualmente")

	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"servico restaurado"}`))
}
