<?php
$vm = $_GET['vm'] ?? '';
$phase = $_GET['phase'] ?? '';
if (!preg_match('/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/', $vm) || !preg_match('/^[a-z0-9_-]{1,32}$/', $phase)) {
    http_response_code(400);
    echo 'invalid';
    exit;
}
$message = date('Y-m-d H:i:s') . ' ' . $vm . ' ' . $phase . "\n";
file_put_contents('/var/www/html/mist-replicator-build.status', $message);
echo 'ok';
