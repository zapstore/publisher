// Global state
let nostrConnected = false;
let userPubkey = null;
let currentSessionData = null;

// Check for NIP-07 extension on page load
document.addEventListener('DOMContentLoaded', function () {
    checkNostrExtension();
});

async function checkNostrExtension() {
    const statusDiv = document.getElementById('nostr-info');
    const connectBtn = document.getElementById('connect-btn');

    if (typeof window.nostr !== 'undefined') {
        statusDiv.innerHTML = 'OK: NIP-07 extension detected!';
        connectBtn.disabled = false;
        connectBtn.textContent = 'Connect Nostr Extension';
    } else {
        statusDiv.innerHTML = 'ERROR: No NIP-07 extension found. Please install Alby, nos2x, or similar.';
        connectBtn.disabled = true;
        setTimeout(checkNostrExtension, 2000); // Retry every 2 seconds
    }
}

async function connectNostr() {
    const statusDiv = document.getElementById('nostr-info');
    const connectBtn = document.getElementById('connect-btn');
    const uploadForm = document.getElementById('upload-form');

    try {
        updateStatus('CONNECTING: Connecting to Nostr extension...\n\nIf this hangs, please check that your extension is unlocked and approve the connection request.');

        // Add timeout to prevent infinite hanging
        const timeout = new Promise((_, reject) =>
            setTimeout(() => reject(new Error('Connection timeout - extension may need approval')), 10000)
        );

        // Get public key from extension with timeout
        userPubkey = await Promise.race([
            window.nostr.getPublicKey(),
            timeout
        ]);

        if (!userPubkey) {
            throw new Error('No public key returned from extension');
        }

        statusDiv.innerHTML = `CONNECTED! Public Key: ${userPubkey.substring(0, 16)}...`;
        connectBtn.textContent = 'CONNECTED';
        connectBtn.disabled = true;

        // Show upload form
        uploadForm.style.display = 'block';
        nostrConnected = true;

        updateStatus(`SUCCESS: Connected to Nostr!\n\nYour pubkey: ${userPubkey}\n\nYou can now upload and publish APK files!`);

    } catch (error) {
        console.error('Nostr connection error:', error);
        statusDiv.innerHTML = 'ERROR: Failed to connect to Nostr extension';
        connectBtn.disabled = false;

        let errorMessage = `ERROR: ${error.message}`;

        if (error.message.includes('timeout')) {
            errorMessage += '\n\nTroubleshooting:\n' +
                '- Check if your extension is unlocked\n' +
                '- Look for permission popup from extension\n' +
                '- Try refreshing the page and connecting again\n' +
                '- Make sure extension is properly installed';
        }

        updateStatus(errorMessage);
    }
}

async function publishApk() {
    if (!nostrConnected) {
        updateStatus('ERROR: Please connect your Nostr extension first!');
        return;
    }

    const apkUrlInput = document.getElementById('apk-url');
    const repositoryInput = document.getElementById('repository');
    const iconUrlInput = document.getElementById('icon-url');
    const descriptionInput = document.getElementById('description');
    const licenseInput = document.getElementById('license');
    const publishBtn = document.getElementById('publish-btn');

    const apkUrl = apkUrlInput.value.trim();
    const repositoryUrl = repositoryInput.value.trim();
    const iconUrl = iconUrlInput.value.trim();
    const description = descriptionInput.value.trim();
    const license = licenseInput.value.trim();

    // Validate APK URL
    if (!apkUrl) {
        updateStatus('ERROR: Please provide an APK download URL!');
        return;
    }

    if (!apkUrl.startsWith('http://') && !apkUrl.startsWith('https://')) {
        updateStatus('ERROR: APK URL must be a valid HTTP/HTTPS URL!');
        return;
    }

    // Validate Repository URL
    if (!repositoryUrl) {
        updateStatus('ERROR: Please provide a repository URL!');
        return;
    }

    if (!repositoryUrl.startsWith('http://') && !repositoryUrl.startsWith('https://')) {
        updateStatus('ERROR: Repository URL must be a valid HTTP/HTTPS URL!');
        return;
    }

    // Validate Icon URL
    if (!iconUrl) {
        updateStatus('ERROR: Please provide an icon URL!');
        return;
    }

    if (!iconUrl.startsWith('http://') && !iconUrl.startsWith('https://')) {
        updateStatus('ERROR: Icon URL must be a valid HTTP/HTTPS URL!');
        return;
    }

    publishBtn.disabled = true;
    showLoading(true);

    try {
        updateStatus('DOWNLOADING: Fetching APK from URL...');

        // Create request data
        const requestData = {
            apkUrl: apkUrl,
            repository: repositoryUrl,
            iconUrl: iconUrl,
            npub: userPubkey
        };

        // Add optional fields if provided
        if (description) {
            requestData.description = description;
        }
        if (license) {
            requestData.license = license;
        }

        // Send to backend
        const response = await fetch('/api/process', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(requestData)
        });

        const result = await response.json();

        if (!response.ok) {
            throw new Error(result.error || 'Processing failed');
        }

        // Store session data for later signing
        currentSessionData = result;

        // Display events for review
        displayEventsForReview(result.events);

        updateStatus('SUCCESS: APK processed! Please review the events below and click SIGN to continue.');

    } catch (error) {
        updateStatus(`ERROR: ${error.message}`);
        publishBtn.disabled = false;
    } finally {
        showLoading(false);
    }
}

function getKindDescription(kind) {
    switch (kind) {
        case 32267:
            return 'Application Description';
        case 30063:
            return 'Release Event';
        case 1063:
            return 'Asset Event (File Metadata)';
        default:
            return `Unknown Kind ${kind}`;
    }
}

function displayEventsForReview(events) {
    const eventsSection = document.getElementById('events-section');
    const eventsDisplay = document.getElementById('events-display');

    // Clear previous events
    eventsDisplay.innerHTML = '';

    events.forEach((event, index) => {
        const eventDiv = document.createElement('div');
        eventDiv.className = 'event-item';

        const eventHeader = document.createElement('div');
        eventHeader.className = 'event-header';
        eventHeader.textContent = `Event ${index + 1} - ${getKindDescription(event.kind)} (Kind ${event.kind})`;

        const eventContent = document.createElement('div');
        eventContent.className = 'event-content';
        eventContent.textContent = JSON.stringify(event, null, 2);

        eventDiv.appendChild(eventHeader);
        eventDiv.appendChild(eventContent);
        eventsDisplay.appendChild(eventDiv);
    });

    // Show the events section
    eventsSection.style.display = 'block';
}

async function signAndPublishEvents() {
    if (!currentSessionData) {
        updateStatus('ERROR: No session data available. Please upload an APK first.');
        return;
    }

    const signBtn = document.getElementById('sign-events-btn');
    signBtn.disabled = true;
    showLoading(true);

    try {
        updateStatus('SIGNING: Please approve each event in your Nostr extension...');

        // Sign the events
        const signedEvents = [];
        for (let i = 0; i < currentSessionData.events.length; i++) {
            updateStatus(`SIGNING: Event ${i + 1}/${currentSessionData.events.length}...`);

            const signedEvent = await window.nostr.signEvent(currentSessionData.events[i]);
            signedEvents.push(signedEvent);
        }

        updateStatus('PUBLISHING: Sending signed events to relays...');

        // Send signed events back to server
        const publishResponse = await fetch('/api/publish', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                sessionId: currentSessionData.sessionId,
                signedEvents: signedEvents
            })
        });

        const publishResult = await publishResponse.json();

        if (!publishResponse.ok) {
            throw new Error(publishResult.error || 'Publishing failed');
        }

        updateStatus(`SUCCESS! APK published to Zapstore!\n\n${publishResult.message}\n\nYour app is now available on the decentralized app store!`);

        // Show fire.gif
        showSuccessFire();

        // Reset UI and clear form fields
        document.getElementById('events-section').style.display = 'none';
        document.getElementById('publish-btn').disabled = false;
        clearFormFields();
        currentSessionData = null;

    } catch (error) {
        updateStatus(`ERROR: ${error.message}`);
        signBtn.disabled = false;
    } finally {
        showLoading(false);
    }
}

function updateStatus(message) {
    const statusDiv = document.getElementById('status');
    const timestamp = new Date().toLocaleTimeString();
    statusDiv.textContent = `[${timestamp}] ${message}`;
}

function showLoading(show) {
    const loading = document.getElementById('loading');
    loading.style.display = show ? 'block' : 'none';
}

function showSuccessFire() {
    const successFire = document.getElementById('success-fire');
    successFire.style.display = 'block';
}

function clearFormFields() {
    document.getElementById('apk-url').value = '';
    document.getElementById('repository').value = '';
    document.getElementById('icon-url').value = '';
    document.getElementById('description').value = '';
    document.getElementById('license').value = '';
}