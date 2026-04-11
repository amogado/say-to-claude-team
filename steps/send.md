# Send — Envoyer un message

## Si le sender est actif (queue-sender dans la team)

Deleguer via SendMessage :
```
SendMessage(to: "queue-sender", message: "send <target> <type> <body>")
```

Le sender execute send.sh et confirme avec UUID + nombre de destinataires.

## Si le sender n'est pas actif

Envoyer directement :
```bash
TEAM_SESSION_BIT=<bit> bash <SKILL_DIR>/scripts/send.sh "<target>" "<type>" "<body>"
```

## Parsing des arguments

- `send all text "message"` → target=all, type=text, body=message
- `send <session> command "instruction"` → target=session, type=command, body=instruction
- `send <session> query "question"` → target=session, type=query, body=question
- `send broadcast "message"` → target=all, type=text, body=message
- Texte libre → interpreter l'intention, choisir target/type/body
