# Fonte unica da verdade dos manifestos

O ArgoCD gerencia esta pasta. Nada aqui deve ser aplicado com
`kubectl apply` a mao.

## Quem escreve o que

| Campo | Quem edita |
|---|---|
| tag da imagem | o pipeline de CI, automaticamente |
| todo o resto | pessoas, por commit |

A tag da imagem e reescrita pelo job `update-gitops` de cada workflow em
`.github/workflows/ci-*.yml`. O fluxo completo:

```
commit no servico
  -> CI roda teste, SAST, SCA, Trivy
  -> publica a imagem no ECR com a tag <sha>
  -> reescreve a tag neste manifesto e commita
  -> ArgoCD percebe o commit e sincroniza o cluster
```

Ninguem roda `kubectl` nesse caminho. E a propriedade que define GitOps:
o estado do cluster e derivado do Git, nao de comandos.

## Historico

Estes manifestos existiam em duplicata, aqui e em
`togglemaster-infra/k8s/`. A segunda copia foi removida em 2026-11-10,
porque as duas divergiram na primeira execucao do CI (`:v1` de um lado,
SHA do outro) e um `kubectl apply` na copia antiga entraria em laco com
o ArgoCD.

## O que ficou de fora, e por que

`db-init` e um Job de execucao unica. Job no Kubernetes e praticamente
imutavel, entao sob o ArgoCD ele ficaria `OutOfSync` para sempre ou seria
recriado a cada sync. Mora em `togglemaster-infra/jobs/` e roda a mao.

Os dois Secrets tambem nao estao aqui, de proposito: `togglemaster-app-secrets`
(URLs de banco e MASTER_KEY) e `evaluation-service-secret` (SERVICE_API_KEY).
Senha nao entra no Git. Em producao isso seria resolvido com External
Secrets Operator ou Sealed Secrets, lendo do AWS Secrets Manager; aqui sao
criados por script (`tc4-temp/post-apply.ps1` e `create-api-key.ps1`).
