package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
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
