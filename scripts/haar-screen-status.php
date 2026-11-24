<?php
/**
 * Machine-readable status feed for the JOS multicast wait TUI.
 *
 * A booting client already speaks plain text to FOG's service endpoints, so
 * this returns one KEY=value per line. The client draws those lines in a
 * full-screen view and adds its own local link speed and identity.
 *
 * Like haar-autojoin.php, this is MAC-resolved and unauthenticated by design;
 * it only reports state and never creates or changes a task.
 */

use FOG\Base\FOGCore;
use FOG\Items\MulticastSession;
use FOG\Router\Route;

define('FOG_MACHINE_REQUEST', true);

require '../commons/base.inc.php';

header('Content-Type: text/plain');

/** Emit one line of the status feed. */
function haar_status($key, $value)
{
    echo $key . '=' . str_replace(["\r", "\n"], ' ', (string)$value) . "\n";
}

$remote = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
$allowed = in_array($remote, ['127.0.0.1', '::1'], true)
    || strpos($remote, '10.99.0.') === 0;
if (!$allowed) {
    http_response_code(403);
    echo "ERROR forbidden\n";
    exit;
}

haar_status('appliance', gethostname());
haar_status('time', date('Y-m-d H:i:s'));

// Which host is asking, so the TUI can show its assigned image/task.
$mac = (string)filter_input(INPUT_POST, 'mac');
if ($mac === '') {
    $mac = (string)filter_input(INPUT_GET, 'mac');
}
if ($mac !== '') {
    FOGCore::getHostItem(false, false, true, false, false, $mac);
    $Host = FOGCore::$Host;
    if ($Host->isValid()) {
        haar_status('host', $Host->get('name'));
        haar_status('host_id', $Host->get('id'));
        $image = $Host->getImage();
        haar_status('host_image', $image && $image->isValid() ? $image->get('name') : '');
        $task = $Host->get('task');
        if ($task->isValid()) {
            haar_status('task', $task->get('name'));
            haar_status('task_id', $task->get('id'));
            haar_status('task_state', $task->get('stateID'));
        }
    }
}

// The joinable/waiting multicast sessions. Report all of them so a client
// waiting on a second queue still sees useful information.
$where = [
    'stateID' => FOGCore::fastmerge(
        FOGCore::getQueuedStates(),
        (array)FOGCore::getProgressState()
    ),
];
$rows = Route::getList('multicastsession', $where);
haar_status('sessions', count($rows));
foreach ($rows as $index => $row) {
    $s = new MulticastSession((int)$row->id);
    if (!$s->isValid()) {
        continue;
    }
    $prefix = 'session' . $index . '_';
    haar_status($prefix . 'id', $s->get('id'));
    haar_status($prefix . 'name', $s->get('name'));
    haar_status($prefix . 'state', $s->get('stateID'));
    haar_status($prefix . 'image', $s->getImage()->get('name'));
    haar_status($prefix . 'port', $s->get('baseport'));
    haar_status($prefix . 'clients', $s->get('clients'));
    haar_status($prefix . 'sessclients', $s->get('sessclients'));
    haar_status($prefix . 'maxwait', $s->get('maxwait'));
    haar_status($prefix . 'senderstart', $s->get('senderstart'));
    haar_status($prefix . 'percent', $s->get('percent'));
}

// Surrounding systems the operator cares about while a room is waiting.
$services = [
    'fog_multicast' => 'FOGMulticastManager',
    'dnsmasq'       => 'dnsmasq',
    'nfs'           => 'nfs-kernel-server',
    'mobile_api'    => 'haar-mobile-api',
    'imaging_api'   => 'haar-imaging-api',
    'model_api'     => 'haar-model-api',
];
foreach ($services as $key => $unit) {
    $state = trim((string)shell_exec('systemctl is-active ' . escapeshellarg($unit) . ' 2>/dev/null'));
    haar_status('svc_' . $key, $state === '' ? 'unknown' : $state);
}

// Imaging and AP addresses, taken from the appliance's own configuration.
$imagingIp = trim((string)FOGCore::getSetting('FOG_MULTICAST_RENDEZVOUS'));
if ($imagingIp === '') {
    $imagingIp = '10.99.0.1';
}
haar_status('imaging_ip', $imagingIp);
haar_status('imaging_iface', trim((string)FOGCore::getSetting('FOG_UDPCAST_INTERFACE')));
$links = trim((string)shell_exec('ip -br -4 addr show 2>/dev/null'));
foreach (explode("\n", $links) as $link) {
    if (strpos($link, '10.99.0.') !== false || strpos($link, '10.42.0.') !== false) {
        haar_status('link', trim($link));
    }
}
