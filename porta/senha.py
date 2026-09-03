#!/usr/bin/env python3
# =========================================================================
# senha.py — define/troca a senha mestra do modo MASTER (chat + porta).
#
# Rodar NO SHELL DO HOST (SSH), como root:
#     motobase senha        (atalho de: python3 /opt/porta/senha.py)
#
# A senha não trafega pelo chat na criação e não fica em texto em lugar
# nenhum: guarda-se só o scrypt dela em /opt/porta/auth.json (0600).
# Trocar a senha também zera qualquer castigo de tentativas erradas.
# O instalador chama com a senha por argumento (definição inicial, sem prompt).
# =========================================================================
import getpass
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import auth  # noqa: E402

MIN = 8


def main():
    if len(sys.argv) > 1:
        if len(sys.argv[1]) < MIN:
            print('Curta demais — nada foi alterado.')
            return 1
        auth.definir_senha(sys.argv[1])
        print('Senha gravada.')
        return 0
    print('Senha mestra do modo MASTER do chat. Mínimo %d caracteres.' % MIN)
    p1 = getpass.getpass('Nova senha: ')
    if len(p1) < MIN:
        print('Curta demais — nada foi alterado.')
        return 1
    p2 = getpass.getpass('Repete: ')
    if p1 != p2:
        print('As duas não bateram — nada foi alterado.')
        return 1
    auth.definir_senha(p1)
    print('Senha gravada (hash scrypt em /opt/porta/auth.json). '
          'Castigo de tentativas zerado.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
