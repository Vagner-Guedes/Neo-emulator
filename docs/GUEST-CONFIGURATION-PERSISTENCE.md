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
