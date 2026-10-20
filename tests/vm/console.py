#!/usr/bin/env python3
"""Console serial da VM de teste: espera um texto na tela e digita a resposta.

    console.py SOCK luks SENHA         digita a senha do LUKS quando o boot pedir
    console.py SOCK sem-senha [SEG]    o boot chega ao login sem pedir senha (TPM abriu o disco)
    console.py SOCK pede-senha SENHA   o TPM não abre o disco sozinho; depois digita a senha
    console.py SOCK mok SENHA          confirma a chave pendente no MokManager
    console.py SOCK boot SENHA         chega ao login; digita a senha só se o TPM não abrir o disco

Sai com 1 e mostra o fim da tela quando o esperado não aparece no prazo.
"""
import re
import select
import socket
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>78]")
DESBLOQUEIO = rb"Please unlock disk|Please enter passphrase for disk"
LOGIN = rb"login:"
BAIXO = b"\x1b[B"
ENTER = b"\r"


class Console:
    def __init__(self, caminho):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(caminho)
        self.tela = b""

    def _le(self, ate):
        while time.monotonic() < ate:
            pronto, _, _ = select.select([self.sock], [], [], 0.5)
            if pronto:
                dados = self.sock.recv(65536)
                if not dados:
                    raise SystemExit("o console fechou (a VM desligou?)")
                self.tela += ANSI.sub(b" ", dados)
                return True
        return False

    def espera(self, padrao, segundos, consome=True):
        ate = time.monotonic() + segundos
        while True:
            achou = re.search(padrao, self.tela)
            if achou:
                if consome:
                    self.tela = self.tela[achou.end():]
                return achou
            if not self._le(ate):
                return None

    def envia(self, dados, pausa=0.7):
        time.sleep(pausa)
        self.sock.sendall(dados)

    def digita(self, texto):
        for c in texto.encode():
            self.envia(bytes([c]), pausa=0.05)

    def falha(self, motivo):
        fim = self.tela[-1500:].decode(errors="replace")
        raise SystemExit(f"FALHOU: {motivo}\n--- fim da tela ---\n{fim}")


def luks(c, senha):
    if not c.espera(DESBLOQUEIO, 300):
        c.falha("o boot não pediu a senha do LUKS")
    c.digita(senha)
    c.envia(ENTER)
    if not c.espera(LOGIN, 300):
        c.falha("não chegou ao login depois da senha")


def sem_senha(c, segundos="300"):
    if not c.espera(LOGIN, int(segundos)):
        c.falha("não chegou ao login sem senha")


def pede_senha(c, senha):
    if not c.espera(DESBLOQUEIO, 300):
        c.falha("o boot não chegou ao pedido de senha")
    # O clevis tenta o TPM em paralelo com o pedido; se abrisse, o login viria.
    if c.espera(LOGIN, 90):
        c.falha("o TPM abriu o disco, e não devia")
    c.digita(senha)
    c.envia(ENTER)
    if not c.espera(LOGIN, 300):
        c.falha("não chegou ao login depois da senha")


def boot(c, senha):
    achou = c.espera(DESBLOQUEIO + b"|" + LOGIN, 300)
    if not achou:
        c.falha("o boot não chegou nem ao pedido de senha nem ao login")
    if achou.group(0) == LOGIN or c.espera(LOGIN, 60):
        print("sem senha")
        return
    c.digita(senha)
    c.envia(ENTER)
    if not c.espera(LOGIN, 300):
        c.falha("não chegou ao login depois da senha")
    print("pediu senha")


def mok(c, senha):
    if not c.espera(rb"Press any key to perform MOK management", 300):
        c.falha("o MokManager não apareceu")
    c.envia(b" ", pausa=0.2)
    passos = [
        (rb"Enroll MOK", [BAIXO, ENTER]),
        (rb"View key 0", [BAIXO, ENTER]),
        (rb"Enroll the key", [BAIXO, ENTER]),
    ]
    for texto, teclas in passos:
        if not c.espera(texto, 60):
            c.falha(f"o MokManager não mostrou {texto.decode()}")
        for t in teclas:
            c.envia(t)
    if not c.espera(rb"Password", 60):
        c.falha("o MokManager não pediu a senha")
    c.digita(senha)
    c.envia(ENTER)
    if not c.espera(rb"Reboot", 60):
        c.falha("o MokManager não ofereceu reiniciar")
    c.envia(ENTER)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    c = Console(sys.argv[1])
    acao, args = sys.argv[2], sys.argv[3:]
    {"luks": luks, "sem-senha": sem_senha, "pede-senha": pede_senha, "mok": mok,
     "boot": boot}[acao](c, *args)
    print(f"ok: {acao}")


if __name__ == "__main__":
    main()
