"""Divide um arquivo SQL em comandos individuais (um por saída, separados por \\0).

Respeita aspas simples, identificadores entre aspas duplas, corpos $$...$$ /
$tag$...$tag$ e comentários (-- e /* */). Usado para simular um cliente que
executa cada comando numa transação/conexão separada (como pode acontecer no
SQL Editor do Supabase).

Uso: python3 -I tests/separar_sql.py arquivo.sql  > comandos (separados por NUL)
"""
import re
import sys


def separar(sql):
    comandos, atual, i, n = [], [], 0, len(sql)
    while i < n:
        c = sql[i]
        if sql.startswith("--", i):                      # comentário de linha
            fim = sql.find("\n", i)
            fim = n if fim < 0 else fim
            atual.append(sql[i:fim]); i = fim
        elif sql.startswith("/*", i):                    # comentário de bloco
            fim = sql.find("*/", i + 2)
            fim = n if fim < 0 else fim + 2
            atual.append(sql[i:fim]); i = fim
        elif c in ("'", '"'):                            # 'texto' ou "identificador"
            j = i + 1
            while j < n:
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:    # aspas dobradas
                        j += 2; continue
                    break
                j += 1
            atual.append(sql[i:j + 1]); i = j + 1
        elif c == "$":                                   # $$...$$ ou $tag$...$tag$
            m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$", sql[i:])
            if m:
                tag = m.group(0)
                fim = sql.find(tag, i + len(tag))
                fim = n if fim < 0 else fim + len(tag)
                atual.append(sql[i:fim]); i = fim
            else:
                atual.append(c); i += 1
        elif c == ";":
            texto = "".join(atual).strip()
            if re.sub(r"--[^\n]*|/\*.*?\*/", "", texto, flags=re.S).strip():
                comandos.append(texto + ";")
            atual, i = [], i + 1
        else:
            atual.append(c); i += 1
    resto = "".join(atual).strip()
    if re.sub(r"--[^\n]*|/\*.*?\*/", "", resto, flags=re.S).strip():
        comandos.append(resto)
    return comandos


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as f:
        partes = separar(f.read())
    sys.stdout.write("\0".join(partes))
