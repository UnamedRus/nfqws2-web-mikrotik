# nfqws2-mikrotik

Контейнер для запуска **NFQWS2 (zapret2)** на MikroTik RouterOS (7.21+) со встроенным
веб-интерфейсом [nfqws-keenetic-web](https://github.com/nfqws/nfqws-keenetic-web).
Поддерживаются архитектуры **ARM64** и **AMD64**.

Образ: `ghcr.io/<owner>/nfqws2-mikrotik`

## Установка на MikroTik

```
/interface/bridge add name=Bridge-Docker port-cost-mode=short
/ip/address add address=192.168.254.1/24 interface=Bridge-Docker
/interface/veth add address=192.168.254.7/24 gateway=192.168.254.1 name=NFQWS2
/interface/bridge/port add bridge=Bridge-Docker interface=NFQWS2
/container/add remote-image=ghcr.io/<owner>/nfqws2-mikrotik interface=NFQWS2 \
  root-dir=/usb1/docker/nfqws2-mikrotik start-on-boot=yes logging=yes \
  dns=1.1.1.1,8.8.8.8,9.9.9.9
```

Направьте нужный трафик в контейнер (mark-routing на шлюз `192.168.254.7`), например:

```
/routing table add disabled=no fib name=to_nfqws2
/ip route add check-gateway=ping gateway=192.168.254.7 routing-table=to_nfqws2
/ip firewall mangle add action=mark-routing chain=prerouting dst-address-type=!local \
  in-interface-list=LAN new-routing-mark=to_nfqws2 passthrough=no src-address=<client-ip> place-before=0
```

## Веб-интерфейс

Доступен на `http://192.168.254.7:90` (адрес veth). Авторизация по умолчанию
отключена (`/etc/nfqws_web.conf`, `[auth] enabled = false`), т.к. интерфейс доступен
только во внутренней Docker-сети.

## Конфигурация

Настройки и списки хранятся в `/etc/nfqws2` (`nfqws2.conf`, `lists/*.list`). Смонтируйте
этот путь как volume, чтобы правки сохранялись между перезапусками. Файрвол —
нативный nftables; `nfqws2` работает через NFQUEUE.

> Кнопки обновления/версии в веб-интерфейсе не работают в контейнере (нет opkg/apk) —
> это ожидаемо; редактирование конфигов и управление сервисом работают.