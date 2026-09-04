# Configuração persistente do guest NeoNews

As configurações pontuais homologadas para o Android-x86 ficam versionadas em `config/runtime.json`, na seção `android.guestConfiguration`, e são aplicadas automaticamente pelo launcher antes de iniciar o NeoNews.

## Configurações fixas

- QEMU usa a NIC `e1000` e o guest mantém a interface `eth0`.
- `VIRT_WIFI=0` impede a criação de `virt_wifi`.
- O guest usa `10.0.2.15/24`, gateway `10.0.2.2` e DNS `10.0.2.3`.
- A regra do Superuser para `com.in9midia.neonews.player` é `allow`, permanente (`until=0`) e com `notification=0`.
- A regra é gravada usando o UID real do pacote na máquina atual; o UID não é fixado no projeto.

## Aplicação

`GuestConfigurationService` lê `/system/etc/init.sh`, preserva o conteúdo não relacionado e aplica somente blocos marcados pelo projeto. A alteração é idempotente, remonta `/system` como somente leitura ao final e reinicia o guest apenas quando o arquivo realmente mudou.

O launcher instala/valida o NeoNews antes de gravar a regra do Superuser. Assim, a primeira solicitação de root do aplicativo já encontra `allow` permanente e não gera a mensagem de concessão. A configuração é revalidada em cada inicialização; qualquer falha bloqueia o start do NeoNews.

## Nova máquina

O processo de publicação copia `config/runtime.json`, o launcher compilado e o estado do runtime. Depois de provisionar os componentes locais aprovados e o disco Android, iniciar `NeoNewsRuntime.exe` reaplica as configurações no disco persistente daquela máquina. Credenciais de ativação não são armazenadas no projeto nem nos logs.

Esta etapa não instala, remove, limpa ou substitui RHVoice, WebView, Native Bridge, APKs ou pacotes do debloat.
## Imagem persistente homologada nesta etapa

O projeto agora aponta `config/runtime.json` para
`runtime/android/neonews-runtime-v1.qcow2`. A imagem é standalone, sem
backing file, tem 8 GiB virtuais e 4,02 GiB alocados; SHA-256 do arquivo:
`EA183B11BD9C996BC362D99AA40EAE25995D62516179599D82A1BEAE1E62DD77`.
`qemu-img check` passou sem erros.

Ela foi criada em uma cópia descartável a partir do overlay Native Bridge
oficial, recebeu o WebView 119.0.6045.193 pelo fluxo de provisionamento, foi
validada após reboot independente e depois achatada para eliminar o caminho
absoluto do backing. O cold boot da imagem standalone iniciou o NeoNews com
`primaryCpuAbi=armeabi-v7a` e manteve `TerminalActivity` estável por 60 s.

A prova não promove o conteúdo Power BI: o fluxo real do NeoNews ainda
retorna conteúdo offline ausente. Esse bloqueio permanece explícito no
`config/runtime.json` e nos relatórios de WebView.
