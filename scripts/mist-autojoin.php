<?php
/**
 * MIST auto-join endpoint.
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
 * This is deliberately MAC-resolved and unauthenticated, like FOG's own
 * service endpoints. The caller can only act on the host whose MAC it sent,
 * and the endpoint only creates a task for a session that FOG already says is
 * joinable. The response is plain text so a shell init script can parse it.
 *
 * Installed by mist-autojoin-setup.sh.
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
function mist_autojoin_out($line, $status = 200)
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
function mist_autojoin_register($mac)
{
    $macs = array_values(array_unique(array_filter(array_map(
        'trim',
        explode('|', str_replace([',', ';'], '|', $mac))
    ))));
    if (!count($macs)) {
        mist_autojoin_out('ERROR no usable MAC for registration', 400);
    }

    $primary = $macs[0];
    $suffix = strtolower(str_replace([':', '-', '.'], '', $primary));
    $name = 'MIST-' . substr($suffix, -8);

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
            sprintf('Auto-registered by MIST autojoin on %s', date('Y-m-d H:i:s'))
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
        mist_autojoin_out('ERROR auto-registration failed', 500);
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
function mist_autojoin_ip_in_cidr($ip, $cidr)
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
 * avoids parse_ini_file(): mist.env contains shell comments and quoted UNC
 * values that are valid for bash but not for PHP's INI parser.
 *
 * @param string $file
 *
 * @return array
 */
function mist_autojoin_read_env($file)
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
 * Where may the endpoint be called from? The JOS client is on the imaging
 * subnet; localhost is allowed for the doctor/test. Set
 * JOG_AUTOJOIN_ALLOW_NET (comma-separated CIDRs) to override.
 *
 * @return array
 */
function mist_autojoin_allowed_nets()
{
    $value = getenv('JOG_AUTOJOIN_ALLOW_NET');
    if ($value === false || trim($value) === '') {
        $env = mist_autojoin_read_env('/etc/mist/autojoin.env');
        if (empty($env['JOG_AUTOJOIN_ALLOW_NET'])) {
            $jogEnv = mist_autojoin_read_env('/etc/mist/mist.env');
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
foreach (mist_autojoin_allowed_nets() as $cidr) {
    if (mist_autojoin_ip_in_cidr($remote, $cidr)) {
        $allowed = true;
        break;
    }
}
if (!$allowed) {
    mist_autojoin_out('ERROR forbidden', 403);
}

// Side-effect-free liveness probe. Health checks must not send a MAC: since
// auto-registration was added, a dummy MAC would create a real host record.
if (isset($_GET['probe']) || isset($_POST['probe'])) {
    mist_autojoin_out('OK ALIVE');
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
        mist_autojoin_out('ERROR no MAC supplied', 400);
    }

    FOGCore::getHostItem(false, false, true, false, false, $mac);
    $Host = FOGCore::$Host;
    if (!$Host->isValid()) {
        $Host = mist_autojoin_register($mac);
    }
    if ($Host->get('pending')) {
        mist_autojoin_out('ERROR host is pending registration', 400);
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
            mist_autojoin_out('OK TASK ' . $Task->get('name'));
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
        mist_autojoin_out('NONE');
    }

    // Several named sessions waiting is a human decision. Do not pick one.
    $names = [];
    foreach ($joinable as $session) {
        $names[] = $session->get('name');
    }
    $names = array_values(array_unique($names));
    if (count($names) > 1) {
        mist_autojoin_out('AMBIGUOUS ' . implode(',', $names));
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
        mist_autojoin_out('ERROR multicast task type missing', 500);
    }

    $Host->createImagePackage(
        $tasktype,
        $session->get('name'),
        false,
        false,
        -1,
        false,
        'mist-autojoin',
        '',
        true,
        false
    );

    mist_autojoin_out('OK JOIN ' . $session->get('name'));
} catch (\Exception $e) {
    mist_autojoin_out('ERROR ' . $e->getMessage(), 400);
}
