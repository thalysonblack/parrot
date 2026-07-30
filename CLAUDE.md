# parrot — clone local do Thalyson (com patch pt-BR)

Upstream: https://github.com/digimata/parrot — cópia local com patch, não fork
no GitHub. Ditado por push-to-talk: segura `fn`, fala, solta, o texto entra no
cursor. Irmão do quill (mesmo esqueleto, mesmo tipo de config).

## O patch (por que existe)

O problema real, medido em 29/07/2026 com 7s de pt-BR: o modelo default
(`whisper-base.en`, o ★ do registry) é English-only e, com áudio em português,
**não erra — alucina**:

- falado: "Fecha o escopo do presskit da imersão de cana na Itália e me manda o
  orçamento revisado até quarta-feira."
- `whisper-base.en` devolveu: **"The first thing is to make the world a better place."**

Frase inventada, fluente, em inglês — e o parrot injeta isso direto no cursor.
O conserto é usar `whisper-large-v3-turbo` (multilíngue) **e fazer essa escolha
persistir**.

⚠️ **Uma teoria minha que caiu — não repetir como se fosse verdade.** Eu
diagnostiquei que os defaults do WhisperKit envenenavam o pt: `language` nil +
`usePrefillPrompt` true → `detectLanguage` false → decoder primado com `<|en|>`.
A cadeia existe no código-fonte, mas **não muda o resultado nesse modelo**:
forcei `en`, `pt`, `es` e `ja` no mesmo áudio e as quatro saídas foram
byte-idênticas, em português correto, com o decoder reportando `language: ja`.
O large-v3-turbo praticamente ignora o language token em áudio inequívoco.
`WhisperKitTranscriber` continua declarando as opções explicitamente (é o certo,
e vale para áudio ruidoso/ambíguo), mas **não é isso que faz o pt funcionar**.

Somado a isso:
- `--language <code>` no `run`, validado contra `Constants.languageCodes`, e
  **recusado em modelo `.en`** — essa recusa é a parte que realmente protege:
  impede o cenário da alucinação acima em vez de deixá-lo passar em silêncio.
  `--language auto` pede detecção quando o config já nomeia um idioma (senão o
  config ganha e não há volta sem editar o arquivo).
- `Config.swift` — `~/.config/parrot/config.json` com `model` e `language`.
  Existe porque o LaunchAgent roda `parrot run --skip-doctor` **sem mais
  argumentos**: sem config, o parrot daemonizado fica preso no modelo default em
  inglês, não importa o que você passou na mão a primeira vez.
- `parrot transcribe <arquivo>` — transcreve arquivo em vez do mic. É o único
  jeito de exercitar o caminho modelo+idioma sem segurar `fn` na mão (e serve
  para reproduzir um transcript ruim depois).

Resolução, para os dois: flag > config > default.

## Uso em pt

```sh
parrot models download whisper-large-v3-turbo   # 1.6 GB, uma vez
parrot transcribe /tmp/audio-pt.wav --model whisper-large-v3-turbo --language pt
```

Para ditado diário em um idioma só, **nomear o idioma** em vez de deixar
detectar: numa frase de 2 segundos há pouca evidência acústica, e pt/es/it se
confundem fácil.

## Cuidados

- Modelos do WhisperKit caem em `~/Documents/huggingface` (default do
  swift-transformers Hub, não do parrot). 1,6 GB. Aqui `~/Documents` **não**
  está no iCloud — se um dia estiver, redirecionar, porque modelo evictado pelo
  "Optimize Storage" quebra o parrot offline.
- README do upstream promete duas coisas que o código não faz: `parrot setup`
  não baixa modelo (o download acontece no primeiro `warmUp`, ou via
  `models download`), e `--hotkey` não existe no `Run` — o gatilho é `fn`, fixo.
- Permissões (mic + acessibilidade) grudam no app que executa o binário: no
  terminal, elas vão para o Terminal/Ghostty; como LaunchAgent, para o parrot.
  Trocar de um para o outro exige conceder de novo.

## Build

`swift build -c release` (~2 min limpo). Binário: `/usr/local/bin/parrot`.
