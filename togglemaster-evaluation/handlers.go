package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"

	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

type EvaluationResponse struct {
	FlagName string `json:"flag_name"`
	UserID   string `json:"user_id"`
	Result   bool   `json:"result"`
}

func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	if err := json.NewEncoder(w).Encode(map[string]string{"status": "ok"}); err != nil {
		log.Printf("Erro ao codificar resposta de health check: %v", err)
	}
}

func (a *App) evaluationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Modo de falha injetada. Responder 500 faz a metrica
	// http_server_request_duration_seconds_count ganhar o rotulo
	// http_response_status_code="500", que e exatamente o que o
	// alerta observa.
	if a.Broken.Load() {
		span := trace.SpanFromContext(r.Context())
		span.SetStatus(codes.Error, "falha injetada para demonstracao")

		log.Println("[DEBUG_BREAK] Respondendo 500 por falha injetada")

		http.Error(
			w,
			`{"error": "falha injetada para demonstracao de self-healing"}`,
			http.StatusInternalServerError,
		)
		return
	}

	userID := r.URL.Query().Get("user_id")
	flagName := r.URL.Query().Get("flag_name")

	if userID == "" || flagName == "" {
		http.Error(
			w,
			`{"error": "user_id e flag_name sao obrigatorios"}`,
			http.StatusBadRequest,
		)
		return
	}

	result, err := a.getDecision(r.Context(), userID, flagName)
	if err != nil {
		if _, ok := err.(*NotFoundError); ok {
			result = false
		} else {
			log.Printf("Erro ao avaliar flag: %v", err)
			http.Error(
				w,
				`{"error": "Erro interno ao avaliar a flag"}`,
				http.StatusBadGateway,
			)
			return
		}
	}

	// O envio para o SQS acontece fora do caminho da resposta.
	// context.WithoutCancel preserva o trace mas remove o
	// cancelamento: sem isso, o contexto morre quando o handler
	// retorna e a mensagem nunca chega na fila.
	go a.sendEvaluationEvent(context.WithoutCancel(r.Context()), userID, flagName, result)

	w.WriteHeader(http.StatusOK)

	if err := json.NewEncoder(w).Encode(EvaluationResponse{
		FlagName: flagName,
		UserID:   userID,
		Result:   result,
	}); err != nil {
		log.Printf("Erro ao codificar resposta de avaliacao: %v", err)
	}
}
