# Otimização controlada do guest Android

O guest deve ser tratado como appliance de sinalização. A otimização é
incremental e reversível; não é uma limpeza genérica de Android.

## Fluxo obrigatório

1. `-Mode Audit` espera o Ready Gate, inventaria os comandos ADB definidos na
   especificação e grava `reports/android-packages-before.txt`.
2. O inventário descobre os packages reais, classifica candidatos e atualiza
   `config/android-package-policy.json`. Nenhum package é inventado a partir de
   outra ROM e nenhum package é alterado no modo Audit.
3. O operador revisa `reports/android-debloat-plan.json` e coloca somente os
   candidatos aprovados em `disabled`, com `approved=true` e
   `action=disable-user`.
4. `-Mode Apply` exige snapshot não destrutivo do qcow2 antes da primeira ação,
   valida o guest e executa apenas `pm disable-user --user 0`.
5. Após cada grupo, o guest reinicia e todos os gates funcionais necessários
   são executados. Qualquer falha reativa imediatamente o último grupo com
   `pm enable` e marca `RollbackRequired`.

O gate de cada grupo sempre inclui Package Manager, WebView, NeoNews e a
proteção RHVoice com síntese real. Para promover o resultado a `Optimized`,
execute `Apply -RunFullValidation` com evidências novas do mesmo guest após o
grupo: WebView HTML/CSS/JavaScript e HTTPS, RHVoice/provider e áudio, rede,
HLS/mídia, estabilidade mínima de 600 segundos e checklist final. Evidência
ausente, antiga ou de outro serial é rejeitada e dispara rollback.

Exemplo:

```powershell
.\scripts\provision\Optimize-AndroidGuest.ps1 -Mode Audit

# Depois da revisão humana do plano/política:
.\scripts\provision\Optimize-AndroidGuest.ps1 -Mode Apply -RunFullValidation

# Para desfazer o último grupo aplicado:
.\scripts\provision\Optimize-AndroidGuest.ps1 -Mode Rollback
```

`Audit` é o modo padrão. `Apply` nunca remove APKs, não limpa dados e não
recria o disco. O snapshot é criado em
`runtime/android/backups/neonews-before-debloat.qcow2` e não substitui uma
cópia já existente.

## Proteção absoluta do RHVoice

Antes de qualquer Apply, o inventário identifica todos os packages cujo
manifesto/package dump revela RHVoice e os adiciona automaticamente à lista
`critical` da política. O conjunto observado, caminhos, engine padrão e
resultado do locale ficam registrados no plano.

O otimizador recusa qualquer ação sobre um package RHVoice, critical ou
required. Depois de cada grupo ele confirma novamente:

- todos os packages RHVoice continuam presentes e habilitados;
- `tts_default_synth` não mudou e continua apontando para RHVoice;
- o locale `pt-BR` passa pelo `CHECK_TTS_DATA`;
- a síntese real retorna sucesso e áudio não vazio.

O teste de síntese usa `Test-TtsSynthesis.ps1` sem alterar a engine selecionada
e mantém o probe para evitar qualquer remoção automática. Google TTS só pode
ser tratado como candidato depois de uma homologação explícita do RHVoice; o
otimizador não executa essa desativação.

## Política e estados

`critical`, `required`, `optional`, `disabled` e `unknown` são preenchidos com
dados do guest. A lista `disabled` é a aprovação operacional; estar em
`optional` não autoriza nenhuma ação. Os estados possíveis do relatório são
`NotOptimized`, `AuditComplete`, `DebloatApplied`, `Testing`, `Optimized` e
`RollbackRequired`. O estado `Optimized` exige o gate funcional completo; a
execução parcial nunca o produz.

Todas as ações e reativações são registradas em
`logs/android-optimization.log`, e a comparação antes/depois fica em
`reports/android-optimization-result.md`.
