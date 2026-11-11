#!/usr/bin/perl
# Импорт заказов WB -> МойСклад: запуск на своём Mac (работает и на Linux).
# Скачивает свежую страницу с GitHub Pages, отдаёт её на http://localhost:8787/
# и проксирует запросы /api/ms напрямую в api.moysklad.ru через системный curl
# (без Cloudflare, который режут провайдеры). Токен никуда не сохраняется.
# Нужны только perl и curl, оба встроены в macOS. Только стандартные модули.
#
# Настройки через переменные окружения:
#   WBMS_PORT=8787  WBMS_SITE=https://homeresurs.github.io/wb-moysklad/  WBMS_NO_BROWSER=1

use strict;
use warnings;
use utf8;
use IO::Socket::INET;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use Encode qw(encode_utf8);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
$| = 1;

my $PORT       = $ENV{WBMS_PORT} || 8787;
my $SITE       = $ENV{WBMS_SITE} || 'https://homeresurs.github.io/wb-moysklad/';
my $NO_BROWSER = $ENV{WBMS_NO_BROWSER} ? 1 : 0;
my $MS_BASE    = 'https://api.moysklad.ru/api/remap/1.2';
my @ALLOWED    = ('/entity/', '/context/', '/report/', '/security/token');
my @PASS       = ('x-lognex-retry-after', 'x-ratelimit-remaining', 'x-lognex-retry-timeinterval');
my @FILES      = ('index.html', 'vendor/xlsx.full.min.js');
my $MAX_BODY   = 10 * 1024 * 1024;
my $CLIENT_TIMEOUT = 120;   # сек на один запрос браузера (МойСклад отвечает до 55 с)
my $HOME       = $ENV{HOME} || '.';
my $DIR        = $^O eq 'darwin' ? "$HOME/Library/Application Support/wb-moysklad" : "$HOME/.wb-moysklad";

my %REASON = (200 => 'OK', 201 => 'Created', 204 => 'No Content', 400 => 'Bad Request', 401 => 'Unauthorized',
              403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed', 412 => 'Precondition Failed',
              429 => 'Too Many Requests', 500 => 'Internal Server Error', 502 => 'Bad Gateway', 503 => 'Service Unavailable');

sub logm {
  my @t = localtime;
  printf "[%02d:%02d:%02d] %s\n", $t[2], $t[1], $t[0], shift;
}

sub update_files {
  make_path("$DIR/vendor");
  for my $f (@FILES) {
    my $target = "$DIR/$f";
    my $part   = "$target.part";
    my $rc = system('curl', '-fsSL', '--max-time', '60', '-o', $part, $SITE . $f);
    if ($rc == 0 && -s $part) {
      rename($part, $target) or die "Не удалось сохранить $target: $!\n";
      logm("Обновлён $f");
    } else {
      unlink $part;
      die "Не удалось скачать $SITE$f и нет сохранённой копии. Проверьте интернет.\n" unless -e $target;
      logm("Не удалось обновить $f, использую сохранённую копию");
    }
  }
}

sub json_str {
  my $s = shift;
  $s =~ s/(["\\])/\\$1/g;
  $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord $1)/ge;
  return '"' . $s . '"';
}

sub send_raw {
  my ($c, $status, $ctype, $bytes, $extra) = @_;
  my $head = "HTTP/1.1 $status " . ($REASON{$status} || 'Status') . "\r\n"
           . "Content-Type: $ctype\r\nContent-Length: " . length($bytes) . "\r\n"
           . "Cache-Control: no-store\r\nConnection: close\r\n";
  $head .= "$_: $extra->{$_}\r\n" for sort keys %{ $extra || {} };
  print {$c} $head, "\r\n", $bytes;
}

sub send_json  { my ($c, $status, $json) = @_; send_raw($c, $status, 'application/json; charset=utf-8', encode_utf8($json)); }
sub send_error { my ($c, $status, $msg) = @_; send_json($c, $status, '{"errors":[{"error":' . json_str($msg) . ',"proxy":true}]}'); }

sub send_file {
  my ($c, $name, $ctype) = @_;
  my $path = "$DIR/$name";
  open(my $fh, '<:raw', $path) or return send_error($c, 404, "Файл не найден: $name");
  local $/; my $data = <$fh>; close $fh;
  send_raw($c, 200, $ctype, $data);
}

sub uri_decode {
  my $s = shift;
  $s =~ tr/+/ /;
  $s =~ s/%([0-9A-Fa-f]{2})/chr(hex $1)/ge;
  return $s;
}

sub parse_query {
  my %q;
  for my $pair (split /&/, shift // '') {
    my ($k, $v) = split /=/, $pair, 2;
    $q{ uri_decode($k) } = uri_decode($v // '');
  }
  return \%q;
}

# Байты вне безопасного набора URL кодируем, уже закодированные %XX не трогаем.
sub url_safe {
  my $s = shift;
  $s =~ s/([^A-Za-z0-9\-._~:\/?#\[\]\@!\$&'()*+,;=%])/sprintf('%%%02X', ord $1)/ge;
  return $s;
}

sub proxy {
  my ($c, $method, $h, $q, $body) = @_;
  return send_json($c, 200, '{"ok":true,"proxy":"local"}') if exists $q->{ping};
  return send_error($c, 405, "Метод не поддерживается: $method") unless $method =~ /^(GET|POST|PUT)$/;

  my $path = $q->{path} // '';
  return send_error($c, 400, 'Не указан путь запроса (path).') unless length $path && substr($path, 0, 1) eq '/';
  return send_error($c, 400, 'Недопустимый путь запроса.') if $path =~ m{\.\.|://|\\|[\x00-\x1f]};
  return send_error($c, 403, 'Этот раздел API через прокси недоступен.') unless grep { index($path, $_) == 0 } @ALLOWED;

  my $auth = $h->{'x-ms-authorization'} || $h->{'authorization'} || '';
  return send_error($c, 401, 'Не передан токен или логин/пароль МойСклад.') unless $auth;
  return send_error($c, 400, 'Неверный формат авторизации.') unless $auth =~ m{^(Bearer|Basic) [A-Za-z0-9+/=._\-]+$};

  # Токен передаём curl через файл заголовков, а не в аргументах (их видно в списке процессов).
  my ($hfh, $hfile) = tempfile(UNLINK => 1);
  print {$hfh} "Authorization: $auth\nAccept: application/json;charset=utf-8\nUser-Agent: wb-moysklad-local-mac/2.1\n";
  print {$hfh} "Content-Type: application/json\n" if $method ne 'GET';
  close $hfh;
  my (undef, $dfile) = tempfile(UNLINK => 1);

  my @args = ('-sS', '-g', '--compressed', '--max-time', '55', '-X', $method, '-H', "\@$hfile", '-D', $dfile);
  if ($method ne 'GET') {
    my ($bfh, $bfile) = tempfile(UNLINK => 1);
    binmode $bfh; print {$bfh} $body; close $bfh;
    push @args, '--data-binary', "\@$bfile";
  }
  push @args, $MS_BASE . url_safe($path);

  open(my $out, '-|', 'curl', @args) or return send_error($c, 502, "Не удалось запустить curl: $!");
  binmode $out;
  my $resp = do { local $/; <$out> } // '';
  close $out;
  my $rc = $? >> 8;

  open(my $dfh, '<:raw', $dfile) or return send_error($c, 502, "Сервер не смог связаться с МойСклад (curl код $rc).");
  my $dump = do { local $/; <$dfh> } // '';
  close $dfh;
  # Берём последний блок заголовков: перед ним могут быть «100 Continue» или ответ системного прокси.
  my @blocks = grep { /^HTTP\// } split /\r?\n\r?\n/, $dump;
  my ($status) = @blocks ? $blocks[-1] =~ m{^HTTP/\S+\s+(\d{3})} : ();
  return send_error($c, 502, "Сервер не смог связаться с МойСклад (curl код $rc).") unless $status;

  my %rh;
  for my $line (split /\r?\n/, $blocks[-1]) {
    my ($k, $v) = $line =~ /^([^:]+):\s*(.*)$/ or next;
    $rh{ lc $k } = $v;
  }
  my %extra = map { $_ => $rh{$_} } grep { defined $rh{$_} } @PASS;
  send_raw($c, $status, $rh{'content-type'} || 'application/json; charset=utf-8', $resp, \%extra);
}

sub handle {
  my $c = shift;
  binmode $c;
  local $/ = "\n";
  my $line = <$c>;
  return unless defined $line;
  $line =~ s/\r?\n$//;
  my ($method, $target) = $line =~ m{^([A-Z]+)\s+(\S+)\s+HTTP/} or return send_error($c, 400, 'Некорректный запрос.');

  my %h;
  while (defined(my $l = <$c>)) {
    $l =~ s/\r?\n$//;
    last if $l eq '';
    my ($k, $v) = $l =~ /^([^:]+):\s*(.*)$/ or next;
    $h{ lc $k } = $v;
  }

  my $body = '';
  my $len = $h{'content-length'} || 0;
  return send_error($c, 400, 'Слишком большой запрос.') if $len !~ /^\d+$/ || $len > $MAX_BODY;
  while (length($body) < $len) {
    my $n = read($c, my $buf, $len - length($body));
    last unless $n;
    $body .= $buf;
  }

  my ($path, $query) = split /\?/, $target, 2;
  if    ($path =~ m{^/(index\.html)?$})            { send_file($c, 'index.html', 'text/html; charset=utf-8') }
  elsif ($path =~ m{^/vendor/xlsx\.full\.min\.js$}) { send_file($c, 'vendor/xlsx.full.min.js', 'application/javascript') }
  elsif ($path =~ m{^/api/ms/?$})                  { proxy($c, $method, \%h, parse_query($query), $body) }
  elsif ($path eq '/favicon.ico')                  { send_raw($c, 204, 'text/plain', '') }
  else                                             { send_error($c, 404, "Нет такого адреса: $path") }
}

print "=== Импорт заказов WB -> МойСклад: локальный запуск ===\n";
update_files();

my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $PORT, Proto => 'tcp', Listen => 32, ReuseAddr => 1)
  or die "Порт $PORT занят: инструмент уже запущен в другом окне Терминала? Закройте его или запустите так: WBMS_PORT=8788 perl $0 ($!)\n";

$SIG{CHLD} = 'IGNORE';   # дочерние процессы убираются сами
$SIG{PIPE} = 'IGNORE';   # браузер закрыл соединение раньше времени — не падаем

my $url = "http://localhost:$PORT/";
logm("Готово. Откройте в браузере: $url  (окно Терминала не закрывайте, Ctrl+C — остановить)");
if (!$NO_BROWSER) {
  if    ($^O eq 'darwin') { system('open', $url) }
  elsif ($^O eq 'linux')  { system('xdg-open', $url) }
}

# Каждое соединение — в отдельном процессе: браузер держит лишние «пустые» соединения,
# и один зависший запрос не должен блокировать остальные.
while (1) {
  my $c = $server->accept or next;
  my $pid = fork();
  if (!defined $pid) { logm("Не удалось создать процесс: $!"); close $c; next; }
  if ($pid) { close $c; next; }
  close $server;
  local $SIG{ALRM} = sub { die "таймаут\n" };
  alarm $CLIENT_TIMEOUT;
  eval { handle($c); 1 } or do {
    my $err = $@ || 'неизвестная ошибка';
    chomp $err;
    logm("Ошибка: $err") unless $err eq 'таймаут';
    eval { send_error($c, 500, "Ошибка локального прокси: $err") };
  };
  alarm 0;
  close $c;
  exit 0;
}
