<?php
/**
 * JOG auto-join endpoint.
 *
 * Called by the JOS default PXE entry (jos-taskcheck.sh) after DHCP is up and
 * before the normal FOG host-key/hostinfo handshake. It does one thing:
 *
 *   - if this host is unknown, register it from the booted MAC first — that
 *     is what makes a laptop straight out of the box zero-touch;
 *   - if this host already has a task, leave it alone and say OK TASK;
 *   - if exactly one multicast session is still in its join window, create
 *     the same multicast task association the "Join Multicast Session" menu
 *     would create, and say OK JOIN <name>;
 *   - if none is waiting, say NONE so JOS can fall back to the local disk;
 *   - if several are waiting, refuse to guess and say AMBIGUOUS <names>.
 *
 * It also handles two advisory storage-mode actions from JOS:
 *   - action=storage_report: record the BIOS mode seen on the client; on a
 *     capture, flag the image with that mode so a later deploy can compare;
 *   - action=storage_check: report whether that flag matches the target mode
 *     and whether JOS has the required module. Warnings never block imaging.
 *
 * This is deliberately MAC-resolved and unauthenticated, like FOG's own
 * service endpoints. The caller can only act on the host whose MAC it sent,
 * and the endpoint only creates a task for a session that FOG already says is
 * joinable. The response is plain text so a shell init script can parse it.
 *
 * Installed by jog-autojoin-setup.sh.
 */

use FOG\Base\FOGCore;
use FOG\Items\Host;
use FOG\Items\Image;
use FOG\Items\MulticastSession;
use FOG\Items\Task;
use FOG\Items\TaskType;
use FOG\Router\Route;

define('FOG_MACHINE_REQUEST', true);

require '../commons/base.inc.php';

header('Content-Type: text/plain');

/**
 * Print one machine-readable line and stop.
 *
 * @param string $line
 * @param int    $status HTTP status code
 *
 * @return void
 */
function jog_autojoin_out($line, $status = 200)
{
    http_response_code($status);
    echo $line . "\n";
    exit;
}

/**
 * Register a machine FOG has never seen, from the MAC that booted it.
 *
 * This is the missing half of zero-touch: a laptop out of the box has no
 * host record, so the old endpoint answered "host not registered" and JOS
 * booted the local disk. We mirror FOG's quick registration — deterministic
 * MAC-derived name, default modules, primary MAC — but deliberately assign
 * no image here. The joinable multicast session below supplies the image,
 * exactly as FOG's own "Join Multicast Session" menu does.
 *
 * @param string $mac pipe-separated MACs from the booting NIC
 *
 * @return Host
 */
function jog_autojoin_register($mac)
{
    $macs = array_values(array_unique(array_filter(array_map(
        'trim',
        explode('|', str_replace([',', ';'], '|', $mac))
    ))));
    if (!count($macs)) {
        jog_autojoin_out('ERROR no usable MAC for registration', 400);
    }

    $primary = $macs[0];
    $suffix = strtolower(str_replace([':', '-', '.'], '', $primary));
    $name = 'JOG-' . substr($suffix, -8);

    // A legacy record may already hold the generated name. Keep trying
    // rather than failing the whole first-boot flow on a name collision.
    $base = $name;
    $counter = 1;
    while (count(Route::getIds('host', ['name' => $name]))) {
        $name = $base . '-' . $counter++;
    }

    $modules = Route::getIds('module', ['isDefault' => 1]);

    $Host = new Host();
    $Host
        ->set('name', $name)
        ->set(
            'description',
            sprintf('Auto-registered by JOG autojoin on %s', date('Y-m-d H:i:s'))
        )
        ->set('modules', $modules);
    foreach ($macs as $address) {
        if ($address === $primary) {
            $Host->addPriMAC($address);
        } else {
            $Host->addMAC($address);
        }
    }
    if (!$Host->save()) {
        jog_autojoin_out('ERROR auto-registration failed', 500);
    }
    $Host->load();

    return $Host;
}

/**
 * Is $ip inside $cidr? IPv4 only; the imaging network is IPv4.
 *
 * @param string $ip
 * @param string $cidr
 *
 * @return bool
 */
function jog_autojoin_ip_in_cidr($ip, $cidr)
{
    if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return false;
    }
    list($net, $bits) = array_pad(explode('/', $cidr, 2), 2, null);
    if (!filter_var($net, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) || $bits === null) {
        return false;
    }
    $bits = (int)$bits;
    if ($bits < 0 || $bits > 32) {
        return false;
    }
    $mask = $bits === 0 ? 0 : (0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF;
    return (ip2long($ip) & $mask) === (ip2long($net) & $mask);
}

/**
 * Read the simple KEY=value file used by the appliance. This deliberately
 * avoids parse_ini_file(): jog.env contains shell comments and quoted UNC
 * values that are valid for bash but not for PHP's INI parser.
 *
 * @param string $file
 *
 * @return array
 */
function jog_autojoin_read_env($file)
{
    $values = [];
    if (!is_readable($file)) {
        return $values;
    }
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') {
            continue;
        }
        $eq = strpos($line, '=');
        if ($eq === false) {
            continue;
        }
        $key = trim(substr($line, 0, $eq));
        $value = trim(substr($line, $eq + 1));
        if (strlen($value) > 1) {
            $first = $value[0];
            $last = substr($value, -1);
            if (($first === '"' && $last === '"') || ($first === "'" && $last === "'")) {
                $value = substr($value, 1, -1);
            }
        }
        $values[$key] = $value;
    }
    return $values;
}

/**
 * Storage-mode helpers. JOS reports the BIOS storage mode it detected at boot;
 * on a capture that flag is attached to the image, so a later deploy can warn
 * when the target BIOS mode no longer matches the drivers baked into the image.
 * All state lives in one small JSON file -- no FOG schema change is needed.
 */

function jog_storage_param($name)
{
    $value = filter_input(INPUT_POST, $name);
    if ($value === null || $value === false) {
        $value = filter_input(INPUT_GET, $name);
    }
    return trim((string)$value);
}

function jog_storage_file()
{
    $path = getenv('JOG_STORAGE_MODE_FILE');
    if ($path === false || trim($path) === '') {
        $env = jog_autojoin_read_env('/etc/jog/jog.env');
        $path = isset($env['JOG_STORAGE_MODE_FILE']) ? $env['JOG_STORAGE_MODE_FILE'] : '';
    }
    return trim((string)$path) !== '' ? trim((string)$path) : '/var/lib/jog/storage-modes.json';
}

function jog_storage_load($file)
{
    if (!is_readable($file)) {
        return ['images' => [], 'hosts' => []];
    }
    $data = json_decode((string)file_get_contents($file), true);
    if (!is_array($data)) {
        return ['images' => [], 'hosts' => []];
    }
    foreach (['images', 'hosts'] as $key) {
        if (!isset($data[$key]) || !is_array($data[$key])) {
            $data[$key] = [];
        }
    }
    return $data;
}

function jog_storage_write($file, $data)
{
    $tmp = $file . '.tmp';
    $fp = fopen($tmp, 'c');
    if (!$fp) {
        jog_autojoin_out('ERROR cannot write storage state', 500);
    }
    flock($fp, LOCK_EX);
    ftruncate($fp, 0);
    rewind($fp);
    fwrite($fp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    fflush($fp);
    chmod($tmp, 0664);
    fclose($fp);
    if (!rename($tmp, $file)) {
        jog_autojoin_out('ERROR cannot publish storage state', 500);
    }
}

function jog_storage_mac($raw)
{
    $parts = preg_split('/[^0-9a-fA-F]+/', trim((string)$raw), -1, PREG_SPLIT_NO_EMPTY);
    if (!count($parts)) {
        return '';
    }
    return strtolower(implode(':', $parts));
}

function jog_storage_mode($raw)
{
    $mode = strtoupper(trim((string)$raw));
    if (!preg_match('/^[A-Z0-9_-]{1,32}$/', $mode)) {
        return '';
    }
    return $mode;
}

function jog_storage_image_keys($imgid, $name)
{
    $keys = [];
    $imgid = trim((string)$imgid);
    $name = trim((string)$name);
    if ($imgid !== '') {
        $keys[] = 'id:' . $imgid;
    }
    if ($name !== '') {
        $keys[] = 'name:' . strtolower($name);
    }
    return $keys;
}

function jog_storage_image_mode($data, $imgid, $name)
{
    foreach (jog_storage_image_keys($imgid, $name) as $key) {
        if (isset($data['images'][$key]['mode'])) {
            return (string)$data['images'][$key]['mode'];
        }
    }
    return 'unknown';
}

/**
 * @return array [bool $ok, string $line]
 */
function jog_storage_assess($mode, $support, $image_mode)
{
    $mode = $mode !== '' ? $mode : 'UNKNOWN';
    $support = strtolower(trim((string)$support));
    $image_mode = $image_mode !== '' ? $image_mode : 'unknown';
    $prefix = 'target=' . $mode . ' image=' . $image_mode . ' jos=' . $support;

    if ($mode === 'UNKNOWN') {
        return [false, $prefix . ' verdict=unknown detail=storage mode not detected'];
    }
    if (strpos($support, 'missing:') === 0) {
        return [false, $prefix . ' verdict=warn detail=JOS module missing: ' . substr($support, 8)];
    }
    if (strtolower($image_mode) === 'unknown') {
        return [false, $prefix . ' verdict=warn detail=image has no recorded storage mode'];
    }
    if (strcasecmp($image_mode, $mode) !== 0) {
        return [false, $prefix . ' verdict=warn detail=image drivers captured for a different mode'];
    }
    return [true, $prefix . ' verdict=ok detail=matching driver mode'];
}

/**
 * Where may the endpoint be called from? The JOS client is on the imaging
 * subnet; localhost is allowed for the doctor/test. Set
 * JOG_AUTOJOIN_ALLOW_NET (comma-separated CIDRs) to override.
 *
 * @return array
 */
function jog_autojoin_allowed_nets()
{
    $value = getenv('JOG_AUTOJOIN_ALLOW_NET');
    if ($value === false || trim($value) === '') {
        $env = jog_autojoin_read_env('/etc/jog/autojoin.env');
        if (empty($env['JOG_AUTOJOIN_ALLOW_NET'])) {
            $jogEnv = jog_autojoin_read_env('/etc/jog/jog.env');
            $env = array_merge($jogEnv, $env);
        }
        $value = isset($env['JOG_AUTOJOIN_ALLOW_NET'])
            ? $env['JOG_AUTOJOIN_ALLOW_NET']
            : '';
        if (trim($value) === '' && !empty($env['JOG_IMAGING_IP'])) {
            $prefix = isset($env['JOG_IMAGING_PREFIX'])
                ? (int)$env['JOG_IMAGING_PREFIX']
                : 24;
            $octets = explode('.', $env['JOG_IMAGING_IP']);
            if (count($octets) === 4) {
                $octets[3] = '0';
                $value = implode('.', $octets) . '/' . $prefix;
            }
        }
        if (trim($value) === '') {
            $value = '10.99.0.0/24';
        }
    }
    return array_values(array_filter(array_map('trim', explode(',', $value))));
}

$remote = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
$allowed = ($remote === '127.0.0.1' || $remote === '::1');
foreach (jog_autojoin_allowed_nets() as $cidr) {
    if (jog_autojoin_ip_in_cidr($remote, $cidr)) {
        $allowed = true;
        break;
    }
}
if (!$allowed) {
    jog_autojoin_out('ERROR forbidden', 403);
}

// Side-effect-free liveness probe. Health checks must not send a MAC: since
// auto-registration was added, a dummy MAC would create a real host record.
if (isset($_GET['probe']) || isset($_POST['probe'])) {
    jog_autojoin_out('OK ALIVE');
}
if (jog_storage_param('storage_probe') !== '' || jog_storage_param('action') === 'storage_probe') {
    jog_autojoin_out('OK STORAGE ALIVE');
}

// Storage-mode report/check. Deliberately before the auto-join handshake:
// these calls carry no task intent and must never register a host or create
// a task. They only read/write the small Haar-side mode ledger.
$storage_action = jog_storage_param('action');
if ($storage_action === 'storage_report' || $storage_action === 'storage_check') {
    $storage_file = jog_storage_file();
    $mac = jog_storage_mac(jog_storage_param('mac'));
    $mode = jog_storage_mode(jog_storage_param('mode'));
    $support = jog_storage_param('support');
    $tasktype = strtolower(jog_storage_param('type'));
    $imgid = jog_storage_param('imgid');
    $imagename = jog_storage_param('imagename');

    try {
        $lock = fopen($storage_file . '.lock', 'c');
        if (!$lock) {
            jog_autojoin_out('ERROR cannot lock storage state', 500);
        }
        flock($lock, LOCK_EX);
        $data = jog_storage_load($storage_file);

        if ($mac !== '') {
            $data['hosts'][$mac] = [
                'mode' => $mode !== '' ? $mode : 'UNKNOWN',
                'support' => $support,
                'imageName' => $imagename,
                'imageID' => $imgid,
                'taskType' => $tasktype,
                'updated' => date('c'),
            ];
        }

        if ($storage_action === 'storage_report') {
            $flagged = '-';
            if (preg_match('/^(up|upload|capture)$/', $tasktype) && ($imgid !== '' || $imagename !== '')) {
                $entry = [
                    'mode' => $mode !== '' ? $mode : 'UNKNOWN',
                    'support' => $support,
                    'sourceMAC' => $mac,
                    'imageName' => $imagename,
                    'imageID' => $imgid,
                    'captured' => date('c'),
                ];
                foreach (jog_storage_image_keys($imgid, $imagename) as $key) {
                    $data['images'][$key] = $entry;
                }
                $flagged = implode(',', jog_storage_image_keys($imgid, $imagename));
            }
            jog_storage_write($storage_file, $data);
            flock($lock, LOCK_UN);
            jog_autojoin_out(
                'OK STORAGE mode=' . ($mode !== '' ? $mode : 'UNKNOWN') .
                ' support=' . ($support !== '' ? $support : 'unknown') .
                ' imageFlag=' . $flagged
            );
        }

        // Deploy-side check: prefer the mode JOS just detected, fall back to
        // the last report from this MAC. Image mode comes from the capture flag.
        $check_mode = $mode;
        $check_support = $support;
        if ($check_mode === '' && $mac !== '' && isset($data['hosts'][$mac]['mode'])) {
            $check_mode = (string)$data['hosts'][$mac]['mode'];
        }
        if ($check_support === '' && $mac !== '' && isset($data['hosts'][$mac]['support'])) {
            $check_support = (string)$data['hosts'][$mac]['support'];
        }
        $image_mode = jog_storage_image_mode($data, $imgid, $imagename);
        list($ok, $line) = jog_storage_assess($check_mode, $check_support, $image_mode);
        flock($lock, LOCK_UN);
        jog_autojoin_out(($ok ? 'OK ' : 'WARN ') . $line);
    } catch (\Exception $e) {
        if (isset($lock) && is_resource($lock)) {
            flock($lock, LOCK_UN);
        }
        jog_autojoin_out('ERROR ' . $e->getMessage(), 400);
    }
}

try {
    // boot.php collects every mac* field; do the same so a host registered
    // under a NIC other than the one that booted can still be found.
    $macFields = [
        'mac',
        'mac0',
        'macboot',
        'mac1',
        'mac2',
        'mac3',
        'mac4',
        'mac5',
        'mac6',
        'mac7',
    ];
    $macLists = [];
    foreach ($macFields as $macField) {
        $macLists[] = explode('|', (string)filter_input(INPUT_POST, $macField));
    }
    $mac = FOGCore::fastmerge(...$macLists);
    $mac = implode(
        '|',
        array_values(
            array_unique(
                array_filter($mac)
            )
        )
    );
    if ($mac === '') {
        jog_autojoin_out('ERROR no MAC supplied', 400);
    }

    FOGCore::getHostItem(false, false, true, false, false, $mac);
    $Host = FOGCore::$Host;
    if (!$Host->isValid()) {
        $Host = jog_autojoin_register($mac);
    }
    if ($Host->get('pending')) {
        jog_autojoin_out('ERROR host is pending registration', 400);
    }

    // A boot that aborts after hostgetkey (no task, bad token, power loss)
    // leaves hostInfoLock set. The next boot's hostgetkey then refuses with
    // "Host token is currently in use", hostinfo fails with "Invalid token
    // passed for host", and the laptop drops to local disk -- zero-touch stays
    // broken until an admin clears the flag. We are at the very start of a
    // boot here and the host cannot be imaging yet, so release any stale lock.
    if ($Host->get('tokenlock')) {
        $Host->getManager()->update(
            ['id' => $Host->get('id')],
            '',
            ['tokenlock' => false]
        );
        $Host->set('tokenlock', false);
    }

    // A task may already be queued by the web UI or by an earlier boot. Do
    // not create a second one; JOS will continue into the normal handshake.
    //
    // A multicast task whose session has finished, was cancelled, or lost its
    // association can never progress: the sender is gone, hostinfo has nothing
    // to hand the client, and FOS reboots. Host::loadTask() only selects
    // queued/progress states, so such a task also shadows the join below.
    // Retire it first, then continue as if the host had no task.
    $Task = $Host->get('task');
    if ($Task->isValid()) {
        $stale = false;
        if ($Task->isMulticast()) {
            $msIDs = Route::getIds(
                'multicastsessionassociation',
                ['taskID' => $Task->get('id')],
                'msID'
            );
            $stale = true;
            // A retired session (msState=5, name cleared, senderpid=0) looks
            // "joinable" to isJoinable() because it has no sender, so test the
            // same state/name/size gates the join path uses.
            $joinStates = array_map(
                'intval',
                array_merge(
                    (array)FOGCore::getQueuedStates(),
                    (array)FOGCore::getProgressState()
                )
            );
            foreach ($msIDs as $msID) {
                $ms = new MulticastSession((int)$msID);
                if (!$ms->isValid()) {
                    continue;
                }
                if (!in_array((int)$ms->get('stateID'), $joinStates, true)) {
                    continue;
                }
                if (trim((string)$ms->get('name')) === '') {
                    continue;
                }
                if ((int)$ms->get('sessclients') < 1) {
                    continue;
                }
                if ($ms->isJoinable()) {
                    $stale = false;
                    break;
                }
            }
        }
        if (!$stale) {
            jog_autojoin_out('OK TASK ' . $Task->get('name'));
        }
        $Task
            ->set('stateID', FOGCore::getCompleteState())
            ->save();
        // createImagePackage() guards on $Host->get('task')->isValid(), and a
        // Task object stays valid by id even after its state is changed, so
        // clear the host's cached task as well or it still throws InTask.
        $Host->set('task', new Task());
    }

    // Only sessions FOG itself would allow a client to join. This is the same
    // state/name/size/join-window test as IpxeBootMenu::sesscheck().
    $findWhere = [
        'stateID' => FOGCore::fastmerge(
            FOGCore::getQueuedStates(),
            (array)FOGCore::getProgressState()
        ),
    ];
    // A session belongs to a storage group. FOG's own session-join lookup
    // matches on both name and group, so a session from another group would
    // create a second session rather than joining this one. Prefer sessions
    // in the host image's group; if the host has no usable image, keep the
    // old no-filter behaviour.
    $hostGroupID = 0;
    try {
        $hostImage = $Host->getImage();
        if ($hostImage instanceof Image) {
            $storageGroup = $hostImage->getStorageGroup();
            if ($storageGroup && $storageGroup->isValid()) {
                $hostGroupID = (int)$storageGroup->get('id');
            }
        }
    } catch (\Exception $e) {
        $hostGroupID = 0;
    }

    $sessions = Route::getList('multicastsession', $findWhere);
    $joinable = [];
    foreach ($sessions as $row) {
        // Route::getList() returns plain rows. Rehydrate the item so
        // isJoinable() uses the same sender-window logic as FOG's own
        // "Join Multicast Session" path.
        $session = new MulticastSession((int)$row->id);
        if (!$session->isValid()) {
            continue;
        }
        if (trim((string)$session->get('name')) === '') {
            continue;
        }
        if ((int)$session->get('sessclients') < 1) {
            continue;
        }
        if ($hostGroupID > 0 && (int)$session->get('storagegroupID') !== $hostGroupID) {
            continue;
        }
        if (!$session->isJoinable()) {
            continue;
        }
        $joinable[] = $session;
    }

    if (count($joinable) === 0) {
        jog_autojoin_out('NONE');
    }

    // Several named sessions waiting is a human decision. Do not pick one.
    $names = [];
    foreach ($joinable as $session) {
        $names[] = $session->get('name');
    }
    $names = array_values(array_unique($names));
    if (count($names) > 1) {
        jog_autojoin_out('AMBIGUOUS ' . implode(',', $names));
    }

    $session = $joinable[0];

    // Match IpxeBootMenu::multijoin(): point the host at the session image
    // before creating the association so task creation and hostinfo agree.
    $msImage = $session->getImage()->get('id');
    $hostImage = $Host->getImage();
    if (!($hostImage instanceof Image) || $hostImage->get('id') != $msImage) {
        $Host
            ->set('imagename', $session->getImage())
            ->set('imageID', $msImage)
            ->save();
    }

    $tasktype = Route::getItem('tasktype', TaskType::MULTICAST);
    if (!$tasktype) {
        jog_autojoin_out('ERROR multicast task type missing', 500);
    }

    $Host->createImagePackage(
        $tasktype,
        $session->get('name'),
        false,
        false,
        -1,
        false,
        'jog-autojoin',
        '',
        true,
        false
    );

    jog_autojoin_out('OK JOIN ' . $session->get('name'));
} catch (\Exception $e) {
    jog_autojoin_out('ERROR ' . $e->getMessage(), 400);
}
