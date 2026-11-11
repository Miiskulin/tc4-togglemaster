# Jobs de execucao pontual

Ficam fora do ArgoCD de proposito.

Um `Job` do Kubernetes e praticamente imutavel: nao da pra reaplicar um
Job existente esperando que ele rode de novo. Sob o ArgoCD, isso produz
um de dois comportamentos ruins - a aplicacao fica permanentemente
`OutOfSync`, ou o Job e recriado a cada sincronizacao.

Estes aqui sao rodados a mao, quando necessario:

```powershell
kubectl apply -f togglemaster-infra/jobs/db-init.yaml

# para rodar de novo, apague antes:
kubectl delete job db-init -n togglemaster
kubectl apply  -f togglemaster-infra/jobs/db-init.yaml
```

O `db-init` cria as tabelas nos tres bancos RDS. Ele le host, porta,
usuario e senha do AWS Secrets Manager via Pod Identity - nao recebe
nenhuma credencial por variavel de ambiente nem por Secret do cluster.
