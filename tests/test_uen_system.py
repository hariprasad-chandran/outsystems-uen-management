import unittest
import urllib.request
import json
import time
import ssl

# Bypass macOS missing CA root certificate restriction
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

class TestUENManagementSystem(unittest.TestCase):
    
    OUTSYSTEMS_URL = "https://personal-cff72w6z.outsystemscloud.com/UENManagement/uenlist"
    DATAGOV_API_URL = "https://data.gov.sg/api/action/datastore_search?resource_id=d_3f960c10fed6145404ca7b821f263b87&limit=5"

    def test_01_outsystems_web_app_availability(self):
        """Verify that the OutSystems UEN portal is reachable and returns HTTP 200."""
        req = urllib.request.Request(
            self.OUTSYSTEMS_URL,
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        start_time = time.time()
        with urllib.request.urlopen(req, timeout=15, context=ssl_context) as response:
            status_code = response.getcode()
            content = response.read().decode('utf-8', errors='ignore')
            elapsed_time = time.time() - start_time
            
            self.assertEqual(status_code, 200, f"Expected HTTP 200, got {status_code}")
            self.assertIn("UENManagement", content, "Page does not reference the UENManagement application")
            print(f"\n[PASS] OutSystems web app is healthy (HTTP 200 in {elapsed_time:.2f}s)")

    def test_02_datagov_api_connectivity(self):
        """Verify that data.gov.sg API integration data source is active."""
        req = urllib.request.Request(
            self.DATAGOV_API_URL,
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        with urllib.request.urlopen(req, timeout=15, context=ssl_context) as response:
            status_code = response.getcode()
            self.assertEqual(status_code, 200, f"data.gov.sg returned HTTP {status_code}")
            
            data = json.loads(response.read().decode('utf-8'))
            self.assertTrue(data.get("success"), "data.gov.sg response 'success' was False")
            self.assertIn("result", data, "Missing 'result' node in API payload")
            print("\n[PASS] data.gov.sg API integration data source is active")

    def test_03_datagov_entity_record_schema(self):
        """Verify that records retrieved contain essential business fields."""
        req = urllib.request.Request(
            self.DATAGOV_API_URL,
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        with urllib.request.urlopen(req, timeout=15, context=ssl_context) as response:
            data = json.loads(response.read().decode('utf-8'))
            records = data.get("result", {}).get("records", [])
            
            self.assertGreater(len(records), 0, "No records returned from dataset")
            first_record = records[0]
            
            # Check for UEN identifiers
            has_uen_field = any("uen" in key.lower() for key in first_record.keys())
            self.assertTrue(has_uen_field, f"Missing UEN identifier in record keys: {first_record.keys()}")
            print(f"\n[PASS] Dataset schema validated with {len(records)} sample records")

if __name__ == '__main__':
    unittest.main()
