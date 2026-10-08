# Curso de IA: tres talleres en tu propio servidor con GPU

Cada alumno tiene un servidor Linux en la nube con su propia GPU. Todo lo que hagas ocurre en ese servidor; tu portátil solo necesita una terminal y un navegador.

Los talleres van en orden y cada uno usa lo del anterior:

1. **Taller 1**: despliegas un modelo de lenguaje, le pones una interfaz tipo ChatGPT y le haces responder sobre tus documentos (RAG).
2. **Taller 2**: creas un asistente personal que controlas por voz desde Telegram.
3. **Taller 3**: automatizas la atención al cliente de una pequeña empresa con n8n.

## Antes de empezar

### Tu clave SSH

Si aún no le has enviado tu clave pública al profesor, créala en tu portátil (vale en Windows, macOS y Linux) y envíale el contenido del fichero `.pub`:

```bash
ssh-keygen -t ed25519 -C "tu@correo.com"
cat ~/.ssh/id_ed25519.pub
```

### Conéctate a tu servidor

El profesor te dará un comando como este. Cópialo en tu terminal:

```bash
ssh root@203.0.113.10 -p 40015 -i ~/.ssh/id_ed25519
```

La primera vez pregunta si confías en el servidor: escribe `yes`. Comprueba que tienes GPU:

```bash
nvidia-smi
```

### Tres cosas que conviene saber

- **Los programas se quedan en segundo plano con `tmux`.** Cada servicio que arranques vive en una "sesión" con nombre. Para ver qué hace uno, por ejemplo `webui`: `tmux attach -t webui`. Para salir sin pararlo: pulsa `Ctrl+b` y después `d`.
- **Tus direcciones web** salen de este comando. Guárdalas, las usarás en los talleres 1 y 3:

  ```bash
  echo "Open WebUI: https://$RUNPOD_POD_ID-8080.proxy.runpod.net"
  echo "n8n:        https://$RUNPOD_POD_ID-5678.proxy.runpod.net"
  ```

- **El servidor no guarda nada si se reinicia.** Si el profesor lo reinicia, queda como recién creado y hay que repetir los pasos. Puedes cerrar la terminal y volver a conectarte sin problema: eso no reinicia nada.

---

## Taller 1: tu modelo, con interfaz de chat y RAG

### 1. Instala Ollama y arráncalo

Ollama es el programa que carga el modelo en la GPU y lo sirve.

```bash
curl -fsSL https://ollama.com/install.sh | sh
tmux new -d -s ollama 'ollama serve'
```

### 2. Descarga un modelo y habla con él

```bash
ollama pull gemma4
ollama run gemma4
```

Escríbele algo. Para salir del chat: `/bye`. Mira cuánta memoria de la GPU ocupa el modelo:

```bash
ollama ps
```

### 3. Arranca la interfaz web

Open WebUI es una interfaz como la de ChatGPT que se conecta a tu Ollama. La primera vez tarda entre 2 y 3 minutos en instalarse; el segundo comando espera hasta que esté lista.

```bash
tmux new -d -s webui 'DATA_DIR=/root/open-webui uvx --python 3.11 open-webui@0.11.4 serve --port 8080'
until curl -sf localhost:8080/health >/dev/null; do sleep 5; done; echo "Lista: https://$RUNPOD_POD_ID-8080.proxy.runpod.net"
```

Abre esa dirección en el navegador y crea tu cuenta. La primera cuenta que se registra es la administradora, así que hazlo ya. El correo y la contraseña son solo para tu servidor: pueden ser inventados.

Elige el modelo `gemma4:latest` arriba y chatea. Estás usando un modelo que corre en tu GPU, no un servicio externo.

### 4. RAG: que responda sobre tus documentos

Un modelo no sabe nada de tu negocio. Con RAG le pasas documentos y busca en ellos antes de responder.

1. Crea en tu portátil un fichero `panaderia.txt` con este contenido:

   ```text
   Panadería La Espiga. Horario: de martes a domingo de 7:00 a 14:30, lunes cerrado.
   El pan de centeno cuesta 3,40 euros y la empanada de zamburiñas 18 euros.
   Los encargos se recogen a partir de las 11:00. Teléfono de pedidos: 600 123 987.
   ```

2. En un chat nuevo pregunta: *¿Cuánto cuesta la empanada de zamburiñas y qué día cierra la panadería?* No lo sabrá, o se lo inventará.
3. Ahora adjunta el fichero con el botón **+** del cuadro de mensaje y repite la pregunta. Responderá "18 euros" y "los lunes", y citará el documento.

Para dejar documentos disponibles en todos los chats, crea una base de conocimiento en **Workspace → Knowledge**, sube ahí tus ficheros y, en cualquier chat, escribe `#` para elegirla. Prueba con un PDF tuyo.

**Has terminado el taller 1** cuando el modelo responde con datos de tu documento.

---

## Taller 2: asistente personal con control por voz

OpenClaw es un agente: además de conversar, ejecuta acciones en tu servidor (crear ficheros, lanzar comandos, recordar cosas). Lo vas a manejar desde Telegram, con texto y con notas de voz, usando el modelo del taller 1.

Necesitas Telegram en el móvil.

### 1. Instala Node.js y OpenClaw

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
npm install -g openclaw@2026.9.9
```

### 2. Configúralo con tu modelo local

```bash
openclaw onboard --non-interactive --accept-risk --skip-health \
  --mode local --auth-choice ollama --custom-model-id gemma4 \
  --gateway-bind loopback --skip-skills
```

### 3. Dale oído y voz

Whisper transcribe tus notas de voz en la GPU. Las cinco líneas siguientes hacen que el asistente conteste con voz en español cuando le hablas con voz.

```bash
uv tool install openai-whisper
openclaw config set tts.auto inbound
openclaw config set tts.provider microsoft
openclaw config set tts.providers.microsoft.enabled true
openclaw config set tts.providers.microsoft.speakerVoice es-ES-ElviraNeural
openclaw config set tts.providers.microsoft.lang es-ES
```

### 4. Arranca el asistente y pruébalo desde la terminal

```bash
tmux new -d -s openclaw 'openclaw gateway run'
sleep 20
openclaw agent --agent main --message "Crea un fichero compra.txt en tu workspace con dos líneas: pan y tomates. Después dime qué contiene."
cat ~/.openclaw/workspace/compra.txt
```

El fichero existe de verdad: el asistente no solo ha contestado, ha actuado. Si el comando `openclaw agent` falla a la primera, espera diez segundos y repítelo.

### 5. Conéctalo a Telegram

1. En Telegram, abre un chat con **@BotFather** (comprueba que el nombre es exactamente ese), envía `/newbot` y sigue los pasos. Al final te da un *token* parecido a `123456:ABC-DEF...`.
2. En el servidor, sustituye `TU_TOKEN` por el tuyo:

   ```bash
   openclaw channels add --channel telegram --token TU_TOKEN
   ```

3. En Telegram, abre el chat con tu bot nuevo y envíale `hola`. Te contestará con un código de emparejamiento.
4. En el servidor, aprueba ese código (así solo tú puedes usar tu asistente):

   ```bash
   openclaw pairing list telegram
   openclaw pairing approve telegram EL_CODIGO
   ```

5. Vuelve a escribirle. Ya responde.

### 6. Háblale

Mantén pulsado el micrófono de Telegram y envía una nota de voz, por ejemplo: *"Apunta en mi lista de la compra dos barras de pan y un kilo de tomates"*. La primera nota tarda cerca de medio minuto porque se descarga el modelo de Whisper; las siguientes van rápido. Te contestará con otra nota de voz.

Prueba más cosas:

- *"¿Qué tengo en la lista de la compra?"*
- *"Recuerda que mi reunión con el gestor es el jueves a las diez."* Y más tarde: *"¿Cuándo era mi reunión?"*
- *"¿Cuánto espacio libre queda en el disco?"*

**Has terminado el taller 2** cuando el asistente hace algo que le has pedido de viva voz.

---

## Taller 3: automatiza una pequeña empresa con n8n

Vas a montar la atención al cliente de la Panadería La Espiga: un formulario web recibe el mensaje del cliente, tu modelo local lo clasifica (pedido, consulta o queja) y redacta la respuesta, y el cliente la ve al momento.

### 1. Instala y arranca n8n

La instalación tarda unos 2 minutos. Necesita Node.js, que ya instalaste en el taller 2.

```bash
npm install -g n8n@2.42.5
tmux new -d -s n8n "WEBHOOK_URL=https://$RUNPOD_POD_ID-5678.proxy.runpod.net/ N8N_EDITOR_BASE_URL=https://$RUNPOD_POD_ID-5678.proxy.runpod.net/ N8N_PROXY_HOPS=1 n8n start"
until curl -sf localhost:5678/healthz >/dev/null; do sleep 3; done; echo "Lista: https://$RUNPOD_POD_ID-5678.proxy.runpod.net"
```

Abre la dirección y crea tu cuenta de propietario (de nuevo, datos solo para tu servidor).

### 2. Conecta n8n con tu modelo

En el menú, entra en **Credentials → Create credential**, busca **Ollama** y pon como **Base URL**:

```text
http://127.0.0.1:11434
```

Guarda. Debe decir que la conexión funciona.

### 3. Importa el flujo

Crea un flujo nuevo (**Create workflow**). Copia todo el bloque JSON del final de este documento, haz clic en el lienzo vacío y pega con `Ctrl+V`. Aparecen cinco nodos:

| Nodo | Qué hace |
| --- | --- |
| Formulario de contacto | Publica un formulario web con nombre, correo y mensaje |
| Redactar respuesta | Envía al modelo el mensaje junto con los datos del negocio |
| Modelo local (Ollama) | Tu `gemma4`, el del taller 1 |
| Ordenar datos | Separa la categoría y la respuesta que devuelve el modelo |
| Mostrar respuesta | Enseña la respuesta al cliente |

Abre el nodo **Modelo local (Ollama)** y, en **Credential**, elige la que creaste en el paso 2.

### 4. Pruébalo y publícalo

1. Pulsa **Execute workflow**. Se abre el formulario de prueba: rellénalo con un pedido, por ejemplo *"Quería encargar dos empanadas de zamburiñas para el sábado. ¿A qué hora puedo recogerlas y cuánto es?"*.
2. Mira en el lienzo cómo pasa el dato por cada nodo y abre cada uno para ver qué entró y qué salió. La respuesta debe decir 36 € y "a partir de las 11:00".
3. Pulsa **Publish** para dejarlo funcionando. Tu formulario público queda en:

   ```bash
   echo "https://$RUNPOD_POD_ID-5678.proxy.runpod.net/form/contacto"
   ```

   Pásale la dirección a un compañero y que te escriba una queja.

### 5. Hazlo tuyo

- Abre **Redactar respuesta** y cambia los datos del negocio por los de una empresa real que conozcas.
- Añade al final un nodo **Telegram → Send a text message** con el token de tu bot del taller 2, para que al dueño le llegue un aviso con la categoría y el mensaje de cada cliente.
- Añade un nodo **If** después de **Ordenar datos** para que las quejas sigan un camino distinto.

**Has terminado el taller 3** cuando un compañero rellena tu formulario y recibe una respuesta correcta.

---

## Si algo falla

| Síntoma | Qué hacer |
| --- | --- |
| La web no carga | Mira si el servicio sigue vivo: `tmux ls`. Para ver su error: `tmux attach -t webui` (o `n8n`, `ollama`, `openclaw`). |
| Quiero reiniciar un servicio | `tmux kill-session -t NOMBRE` y vuelve a lanzar su comando `tmux new ...`. |
| `ssh` dice *REMOTE HOST IDENTIFICATION HAS CHANGED* | Tu servidor se ha reiniciado. Pide al profesor el comando nuevo y borra la huella antigua con el comando `ssh-keygen -R ...` que te muestra el propio error. |
| El modelo responde muy lento la primera vez | Es normal: se está cargando en la GPU. Las siguientes respuestas son rápidas. |
| El bot de Telegram no contesta | Comprueba el canal con `openclaw channels status --probe` y que aprobaste el código de emparejamiento. |
| El servidor está roto del todo | Pide al profesor un *reset*: te da uno limpio y repites los pasos. |

## Anexo: flujo de n8n para el taller 3

Copia el bloque entero.

```json
{
  "name": "Panadería La Espiga - atención al cliente",
  "nodes": [
    {
      "parameters": {
        "formTitle": "Panadería La Espiga",
        "formDescription": "Escríbenos tu pedido, duda o queja y te respondemos al momento.",
        "formFields": {
          "values": [
            { "fieldLabel": "Nombre", "requiredField": true },
            { "fieldLabel": "Correo", "fieldType": "email", "requiredField": true },
            { "fieldLabel": "Mensaje", "fieldType": "textarea", "requiredField": true }
          ]
        },
        "responseMode": "lastNode",
        "options": { "path": "contacto" }
      },
      "type": "n8n-nodes-base.formTrigger",
      "typeVersion": 2.2,
      "position": [0, 0],
      "id": "a1a1a1a1-0000-4000-8000-000000000001",
      "name": "Formulario de contacto",
      "webhookId": "contacto"
    },
    {
      "parameters": {
        "promptType": "define",
        "text": "=Eres el asistente de atención al cliente de la Panadería La Espiga.\n\nDatos del negocio:\n- Horario: de martes a domingo de 7:00 a 14:30. Lunes cerrado.\n- Pan de centeno: 3,40 €. Empanada de zamburiñas: 18 €. Barra normal: 1,10 €.\n- Los encargos se recogen a partir de las 11:00 y hay que hacerlos con un día de antelación.\n- Teléfono de pedidos: 600 123 987.\n\nHa escrito {{ $json.Nombre }} con este mensaje:\n\"{{ $json.Mensaje }}\"\n\nDevuelve SOLO un objeto JSON con dos claves:\n- \"categoria\": una de \"pedido\", \"consulta\" o \"queja\".\n- \"respuesta\": una respuesta breve y amable en español para el cliente, usando solo los datos del negocio. Si no sabes algo, dile que llame al teléfono de pedidos."
      },
      "type": "@n8n/n8n-nodes-langchain.chainLlm",
      "typeVersion": 1.5,
      "position": [220, 0],
      "id": "a1a1a1a1-0000-4000-8000-000000000002",
      "name": "Redactar respuesta"
    },
    {
      "parameters": {
        "model": "gemma4:latest",
        "options": { "format": "json", "temperature": 0.2 }
      },
      "type": "@n8n/n8n-nodes-langchain.lmChatOllama",
      "typeVersion": 1,
      "position": [220, 200],
      "id": "a1a1a1a1-0000-4000-8000-000000000003",
      "name": "Modelo local (Ollama)",
      "credentials": { "ollamaApi": { "id": "ollamalocal00001", "name": "Ollama local" } }
    },
    {
      "parameters": {
        "assignments": {
          "assignments": [
            { "id": "b1", "name": "nombre", "value": "={{ $('Formulario de contacto').item.json.Nombre }}", "type": "string" },
            { "id": "b2", "name": "correo", "value": "={{ $('Formulario de contacto').item.json.Correo }}", "type": "string" },
            { "id": "b3", "name": "categoria", "value": "={{ JSON.parse($json.text).categoria }}", "type": "string" },
            { "id": "b4", "name": "respuesta", "value": "={{ JSON.parse($json.text).respuesta }}", "type": "string" }
          ]
        },
        "options": {}
      },
      "type": "n8n-nodes-base.set",
      "typeVersion": 3.4,
      "position": [560, 0],
      "id": "a1a1a1a1-0000-4000-8000-000000000004",
      "name": "Ordenar datos"
    },
    {
      "parameters": {
        "operation": "completion",
        "completionTitle": "=Gracias, {{ $json.nombre }}",
        "completionMessage": "={{ $json.respuesta }}",
        "options": {}
      },
      "type": "n8n-nodes-base.form",
      "typeVersion": 1,
      "position": [780, 0],
      "id": "a1a1a1a1-0000-4000-8000-000000000005",
      "name": "Mostrar respuesta",
      "webhookId": "contacto-fin"
    }
  ],
  "connections": {
    "Formulario de contacto": { "main": [[{ "node": "Redactar respuesta", "type": "main", "index": 0 }]] },
    "Modelo local (Ollama)": { "ai_languageModel": [[{ "node": "Redactar respuesta", "type": "ai_languageModel", "index": 0 }]] },
    "Redactar respuesta": { "main": [[{ "node": "Ordenar datos", "type": "main", "index": 0 }]] },
    "Ordenar datos": { "main": [[{ "node": "Mostrar respuesta", "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1" },
  "pinData": {}
}
```
