#!/usr/bin/env python3
"""
macOS Battery and Charger Information Tool
Combines comprehensive battery and charger statistics with flexible privilege modes.
"""

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from datetime import datetime
from typing import Optional, Dict, Any, List


class Colors:
    """ANSI color codes for terminal output"""
    RESET = '\033[0m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    RED = '\033[31m'
    GREEN = '\033[32m'
    YELLOW = '\033[33m'
    BLUE = '\033[34m'
    MAGENTA = '\033[35m'
    CYAN = '\033[36m'

    @classmethod
    def disable(cls):
        """Disable colors for non-TTY output"""
        cls.RESET = cls.BOLD = cls.DIM = ''
        cls.RED = cls.GREEN = cls.YELLOW = cls.BLUE = cls.MAGENTA = cls.CYAN = ''


class PowerInfo:
    """Main class for gathering power/battery information"""

    def __init__(self, use_sudo: bool = False, use_colors: bool = True):
        self.use_sudo = use_sudo
        if not use_colors or not sys.stdout.isatty():
            Colors.disable()

    def run_command(self, cmd: List[str], check: bool = False) -> Optional[str]:
        """Run a shell command and return output"""
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=10,
                check=check,
                errors='replace'  # Handle non-UTF-8 characters gracefully
            )
            return result.stdout
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, FileNotFoundError, UnicodeDecodeError):
            return None

    @staticmethod
    def decode_manufacturer_data(data: bytes) -> Dict[str, str]:
        """Decode ManufacturerData binary blob to extract model/rev/maker

        Tier 3.3C: Extracts embedded strings from manufacturer data.
        Format appears to be length-prefixed strings.
        """
        result = {}
        try:
            # Try to extract ASCII strings from the binary data
            text = data.decode('ascii', errors='ignore')
            # Look for patterns like "3513", "004", "ATL"
            parts = []
            current = ""
            for char in text:
                if char.isprintable() and not char.isspace():
                    current += char
                elif current:
                    if len(current) >= 2:  # Only keep strings >= 2 chars
                        parts.append(current)
                    current = ""
            if current and len(current) >= 2:
                parts.append(current)

            # Try to identify model, revision, manufacturer
            if len(parts) >= 1:
                result['model'] = parts[0]
            if len(parts) >= 2:
                result['revision'] = parts[1]
            if len(parts) >= 3:
                result['manufacturer'] = parts[2]
        except Exception:
            pass
        return result

    @staticmethod
    def decode_manufacture_date(date_raw: int) -> Optional[str]:
        """Decode battery ManufactureDate to human-readable date

        TI battery chips encode date as ASCII hex in format: M-DD-YY-C
        where M=month (single digit), DD=day, YY=year (20YY), C=lot/revision

        Example: 59589201507123 (0x363231303333) → "621033" → June 21, 2023

        Returns: Human-readable date string like "2023-06-21 (Lot: 3)" or None if decoding fails
        """
        try:
            # Convert to hex and decode as ASCII
            hex_str = hex(date_raw)[2:]
            if len(hex_str) % 2 == 1:
                hex_str = '0' + hex_str

            date_str = bytes.fromhex(hex_str).decode('ascii', errors='ignore')

            # Parse as M-DD-YY-C format (month is single digit)
            if len(date_str) >= 5:
                month = int(date_str[0])
                day = int(date_str[1:3])
                year_suffix = int(date_str[3:5])
                lot_code = date_str[5:] if len(date_str) > 5 else ''

                # Smart year detection: Assume 20YY, but adjust if result is too far in past
                # Batteries older than 10 years are unlikely in active MacBooks
                from datetime import datetime as dt_now
                current_year = dt_now.now().year

                year = 2000 + year_suffix
                # If date would be more than 10 years old, try adding 10 or 20 years
                if year < (current_year - 10):
                    year = 2010 + year_suffix  # Try 2010s
                    if year < (current_year - 10):
                        year = 2020 + year_suffix  # Try 2020s

                # Validate
                if 1 <= month <= 12 and 1 <= day <= 31 and 2000 <= year <= 2099:
                    from datetime import datetime as dt_check
                    try:
                        # Validate date is real
                        dt_check(year, month, day)
                        if lot_code:
                            return f"{year}-{month:02d}-{day:02d} (Lot: {lot_code})"
                        else:
                            return f"{year}-{month:02d}-{day:02d}"
                    except ValueError:
                        pass
        except Exception:
            pass

        return None

    @staticmethod
    def _decode_charger_inhibit_reason(reason: int) -> str:
        """Decode ChargerInhibitReason to human-readable string

        Tier 3.3G: Explains why charging is inhibited.
        """
        # Common inhibit reasons (these are educated guesses)
        reasons = {
            0: "Not inhibited",
            1: "Battery too hot",
            2: "Battery too cold",
            4: "System thermal limiting",
            8: "Optimized battery charging",
            16: "Battery charge limit (80%)",
            32: "Adapter insufficient",
            64: "Battery health protection",
        }

        if reason == 0:
            return "None"

        # Check for multiple reasons (bit flags)
        active_reasons = []
        for bit, desc in reasons.items():
            if bit > 0 and (reason & bit):
                active_reasons.append(desc)

        if active_reasons:
            return ", ".join(active_reasons)
        else:
            return f"Unknown (0x{reason:02X})"

    @staticmethod
    def _decode_not_charging_reason(reason: int) -> str:
        """Decode NotChargingReason to human-readable string

        Explains why battery is not charging even when connected to power.
        """
        # Common not charging reasons based on macOS behavior
        # These are bit flags that can be combined
        reasons = {
            0x0000: "Charging normally",
            0x0001: "Battery fully charged",
            0x0002: "Optimized Battery Charging active",
            0x0004: "Battery too hot",
            0x0008: "Battery too cold",
            0x0010: "Charging suspended (system load)",
            0x0020: "Battery health management",
            0x0040: "Charge limit reached (80%)",
            0x0080: "Adapter insufficient power",
            0x0100: "System using more than adapter provides",
            0x0200: "Waiting for optimal charging time",
            0x0400: "Battery conditioning mode",
            0x0800: "Thermal management",
            0x1000: "Battery calibration",
            0x2000: "Power management override",
            0x4000: "Unknown reason",
            0x8000: "Charger error",
        }

        if reason == 0:
            return "None (charging normally)"

        # Check for exact match first
        if reason in reasons:
            return reasons[reason]

        # Check for bit combinations
        active_reasons = []
        for bit, desc in reasons.items():
            if bit > 0 and (reason & bit):
                active_reasons.append(desc)

        if active_reasons:
            result = ", ".join(active_reasons)
            return f"{result} (0x{reason:04X})"
        else:
            return f"Unknown (0x{reason:04X})"

    @staticmethod
    def _decode_chem_id(chem_id: int) -> Optional[str]:
        """Decode battery ChemID to chemistry name

        Common TI battery chip ChemID values for different Li-ion chemistries
        """
        # Common ChemID mappings (these are examples, actual values may vary by manufacturer)
        chem_ids = {
            29961: "Li-ion (High Energy)",  # 0x7509
            29960: "Li-ion (Standard)",
            29962: "Li-ion (High Power)",
            29963: "Li-ion Polymer",
            # Add more as discovered
        }

        known_chem = chem_ids.get(chem_id)
        if known_chem:
            return f"{known_chem} (ID: {chem_id})"
        else:
            # Return generic with ID
            return f"Li-ion (ID: {chem_id})"

    @staticmethod
    def _decode_charger_config(config: int) -> str:
        """Decode ChargerConfiguration bit flags

        NOTE: Apple does not document the meaning of ChargerConfiguration bits.
        This decoder only shows which bits are set without interpretation.
        """
        # Find active bits
        active_bits = []
        for i in range(16):  # Check all 16 bits
            if config & (1 << i):
                active_bits.append(str(i))

        if active_bits:
            bits_str = ", ".join(active_bits)
            result = f"0x{config:04X} (bits: {bits_str})"
            result += f"\n{' ' * 21}{Colors.YELLOW}⚠️  Bit meanings undocumented by Apple{Colors.RESET}"
            return result
        else:
            return f"0x{config:04X} (no bits set)"

    @staticmethod
    def _decode_charger_family(family_hex: str) -> str:
        """Decode ChargerFamily to provide structural information

        ChargerFamily is a 32-bit identifier from Apple's power management.
        While exact meanings are undocumented, it encodes charger generation
        and capabilities.

        Common patterns:
        - 0xe000xxxx: Modern USB-C PD chargers
        - 0x0000xxxx: Legacy MagSafe or non-PD chargers
        """
        try:
            # Parse hex string (might have 0x prefix)
            if family_hex.startswith('0x'):
                family_val = int(family_hex, 16)
            else:
                family_val = int(family_hex)

            # Break down into bytes for analysis
            byte3 = (family_val >> 24) & 0xFF  # High byte
            byte2 = (family_val >> 16) & 0xFF
            # byte1 and byte0 reserved for future decoding

            # Identify charger generation/type from high bytes
            generation = ""
            if byte3 == 0xe0:
                generation = "USB-C PD charger"
            elif byte3 == 0x00 and byte2 == 0x00:
                generation = "Legacy/MagSafe charger"
            else:
                generation = "Unknown charger type"

            return f"{family_hex} ({generation})"
        except (ValueError, AttributeError):
            return family_hex

    @staticmethod
    def _decode_carrier_mode(carrier_mode: Dict) -> Optional[str]:
        """Decode CarrierMode to human-readable format

        CarrierMode is a shipping/storage mode that maintains battery voltage
        in a safe range during transport to prevent degradation.
        """
        if not isinstance(carrier_mode, dict):
            return None

        high_mv = carrier_mode.get('CarrierModeHighVoltage', 0)
        low_mv = carrier_mode.get('CarrierModeLowVoltage', 0)
        status = carrier_mode.get('CarrierModeStatus', 0)

        if high_mv == 0 and low_mv == 0:
            return None

        status_str = "Active" if status == 1 else "Disabled"
        high_v = high_mv / 1000.0
        low_v = low_mv / 1000.0

        return f"{status_str} (range: {low_v:.1f}V - {high_v:.1f}V)"

    @staticmethod
    def _decode_slow_charging_reason(reason: int) -> str:
        """Decode SlowChargingReason to human-readable string

        Explains why charging is slow (< 20W typically).
        """
        reasons = {
            0x0001: "Battery near full",
            0x0002: "Thermal limiting",
            0x0004: "Battery health protection",
            0x0008: "Optimized charging enabled",
            0x0010: "Low power adapter",
            0x0020: "System load too high",
            0x0040: "Battery temperature protection",
            0x0080: "Charge limit (80%) active",
            0x0100: "Battery conditioning",
            0x0200: "Aging compensation",
        }

        if reason == 0:
            return "None (charging at normal speed)"

        # Check for multiple reasons (bit flags)
        active_reasons = []
        for bit, desc in reasons.items():
            if bit > 0 and (reason & bit):
                active_reasons.append(desc)

        if active_reasons:
            result = ", ".join(active_reasons)
            return f"{result} (0x{reason:04X})"
        else:
            return f"Unknown (0x{reason:04X})"

    @staticmethod
    def _decode_permanent_failure_status(status: int) -> Optional[str]:
        """Decode PermanentFailureStatus bit flags

        Shows catastrophic battery failures (should always be 0 for healthy batteries).
        """
        if status == 0:
            return "None (battery healthy)"

        failures = {
            0x0001: "Cell imbalance failure",
            0x0002: "Safety circuit failure",
            0x0004: "Charge FET failure",
            0x0008: "Discharge FET failure",
            0x0010: "Thermistor failure",
            0x0020: "Fuse blown",
            0x0040: "AFE (Analog Front End) failure",
            0x0080: "Cell failure",
            0x0100: "Over-temperature failure",
            0x0200: "Under-temperature failure",
        }

        active_failures = []
        for bit, desc in failures.items():
            if status & bit:
                active_failures.append(desc)

        if active_failures:
            result = ", ".join(active_failures)
            return f"⚠️  {result} (0x{status:04X})"
        else:
            return f"⚠️  Unknown failure (0x{status:04X})"

    @staticmethod
    def _decode_gauge_flag_raw(flags: int) -> str:
        """Decode GaugeFlagRaw bit flags (battery gauge state)

        Common battery gauge status flags from fuel gauge chips.
        """
        if flags == 0:
            return "None (0x00)"

        flag_bits = {
            0x0001: "Discharge Detected",
            0x0002: "Charge Termination",
            0x0004: "Overcharge Detection",
            0x0008: "Terminate Discharge Alarm",
            0x0010: "Over-Temperature Alarm",
            0x0020: "Terminate Charge Alarm",
            0x0040: "Impedance Measured",
            0x0080: "Fully Charged (fast charge complete, trickle charging)",
            0x0100: "Discharge Inhibit",
            0x0200: "Charge Inhibit",
            0x0400: "Voltage OK (VOK)",
            0x0800: "Ready (RDY)",
            0x1000: "Qualified for Use (QEN)",
            0x2000: "Fast Charge OK",
            0x4000: "Battery Present",
            0x8000: "Valid Data",
        }

        active_flags = []
        for bit, desc in flag_bits.items():
            if flags & bit:
                active_flags.append(desc)

        if active_flags:
            result = ", ".join(active_flags)
            return f"{result} (0x{flags:04X})"
        else:
            # No known flags, just show hex
            return f"0x{flags:04X}"

    @staticmethod
    def _decode_misc_status(status: int) -> str:
        """Decode MiscStatus bit flags (miscellaneous battery status)

        NOTE: Apple does not document the meaning of MiscStatus bits.
        This decoder only shows which bits are set without interpretation.
        """
        if status == 0:
            return "None (0x00)"

        active_bits = []
        for bit in range(16):
            if status & (1 << bit):
                active_bits.append(str(bit))

        bits_str = ", ".join(active_bits)
        return f"0x{status:04X} (bits: {bits_str})"

    @staticmethod
    def _decode_wait_seconds(seconds: int) -> str:
        """Decode wait time in seconds to human-readable format

        Converts seconds to hours/minutes/seconds display.
        """
        if seconds == 0:
            return "0 seconds"

        hours = seconds // 3600
        minutes = (seconds % 3600) // 60
        secs = seconds % 60

        parts = []
        if hours > 0:
            parts.append(f"{hours} hr" if hours == 1 else f"{hours} hrs")
        if minutes > 0:
            parts.append(f"{minutes} min")
        if secs > 0 or len(parts) == 0:
            parts.append(f"{secs} sec")

        result = " ".join(parts)
        return f"{result} ({seconds}s)"

    @staticmethod
    def _decode_charger_id(charger_id: int) -> Optional[str]:
        """Decode ChargerID to manufacturer/model info

        Maps known Apple charger IDs to human-readable names.
        """
        # Known Apple charger IDs (these are examples based on common patterns)
        charger_ids = {
            0x00: "Generic/Third-Party Charger",
            0x01: "Apple 5W USB Power Adapter",
            0x02: "Apple 10W USB Power Adapter",
            0x03: "Apple 12W USB Power Adapter",
            0x04: "Apple 18W USB-C Power Adapter",
            0x05: "Apple 20W USB-C Power Adapter",
            0x06: "Apple 29W USB-C Power Adapter",
            0x07: "Apple 30W USB-C Power Adapter",
            0x08: "Apple 35W Dual USB-C Power Adapter",
            0x09: "Apple 61W USB-C Power Adapter",
            0x0A: "Apple 67W USB-C Power Adapter",
            0x0B: "Apple 87W USB-C Power Adapter",
            0x0C: "Apple 96W USB-C Power Adapter",
            0x0D: "Apple 140W USB-C Power Adapter",
            0x0E: "Apple MagSafe Power Adapter",
            0x0F: "Apple MagSafe 2 Power Adapter",
            0x10: "Apple MagSafe 3 Power Adapter",
            # Add more as discovered
        }

        known_charger = charger_ids.get(charger_id)
        if known_charger:
            return f"{known_charger} (ID: 0x{charger_id:02X})"
        else:
            # Unknown charger - just return hex
            return f"Unknown (ID: 0x{charger_id:02X})"

    @staticmethod
    def _simplify_assertion_name(name: str) -> str:
        """Simplify cryptic power assertion names to human-readable format

        Cleans up technical assertion strings like:
        'app<application.com.apple.MobileSMS.123...>456:FBWorkspace' -> 'Messages app'
        """
        import re

        # Extract app bundle ID if present
        app_match = re.search(r'application\.com\.apple\.([A-Za-z]+)', name)
        if app_match:
            app_name = app_match.group(1)
            # Map common app names
            app_names = {
                'MobileSMS': 'Messages',
                'Safari': 'Safari',
                'Music': 'Music',
                'Mail': 'Mail',
                'Photos': 'Photos',
                'Safari': 'Safari',
                'FaceTime': 'FaceTime',
            }
            readable_name = app_names.get(app_name, app_name)
            return f"{readable_name} app"

        # Check for common system assertions
        if 'Powerd' in name and 'display' in name.lower():
            return "Display active (system)"
        if 'Powerd' in name:
            return "System power management"
        if 'kernel' in name.lower():
            return "Kernel task"
        if 'coreaudio' in name.lower():
            return "Audio playback"

        # If no simplification possible, return cleaned up version (truncate if too long)
        if len(name) > 60:
            return name[:57] + "..."
        return name

    @staticmethod
    def _decode_power_state(state: int) -> str:
        """Decode USB-C PD port power state

        Maps power state values to human-readable descriptions.
        States based on USB Type-C Port Controller specification.
        """
        power_states = {
            0x00: "Disabled",
            0x01: "ErrorRecovery",
            0x02: "Unattached.SNK",
            0x03: "Unattached.SRC",
            0x04: "AttachWait.SNK",
            0x05: "AttachWait.SRC",
            0x06: "Attached.SNK",
            0x07: "Attached.SRC",
            0x08: "Try.SRC",
            0x09: "Try.SNK",
            0x0A: "TryWait.SNK",
            0x0B: "TryWait.SRC",
            0x0C: "AudioAccessory",
            0x0D: "DebugAccessory.SNK",
            0x0E: "DebugAccessory.SRC",
            0xFF: "Active/Normal Operation",
        }

        state_name = power_states.get(state)
        if state_name:
            return f"0x{state:02X} ({state_name})"
        else:
            return f"0x{state:02X} (Unknown state)"

    @staticmethod
    def _decode_time_minutes(minutes: int) -> str:
        """Decode time in minutes to human-readable format

        Converts minutes to hours/minutes display.
        Handles special case 0xFFFF (65535) = Not available/infinite
        """
        # Special case: 0xFFFF means not available or infinite
        if minutes == 65535 or minutes == 0xFFFF:
            return "Not available"

        if minutes == 0:
            return "0 minutes"

        hours = minutes // 60
        mins = minutes % 60

        parts = []
        if hours > 0:
            parts.append(f"{hours} hr" if hours == 1 else f"{hours} hrs")
        if mins > 0 or len(parts) == 0:
            parts.append(f"{mins} min")

        result = " ".join(parts)
        return f"{result} ({minutes} min)"

    def get_ioreg_data(self, class_name: str, use_archive: bool = False) -> Optional[Dict]:
        """Get ioreg data for a specific class"""
        cmd = ['ioreg', '-r', '-c', class_name]
        if use_archive and self.use_sudo:
            cmd.append('-a')

        output = self.run_command(cmd)
        if not output:
            return None

        try:
            return plistlib.loads(output.encode())
        except Exception:
            return None

    def get_pmset_battery(self) -> Dict[str, Any]:
        """Get battery information from pmset"""
        output = self.run_command(['pmset', '-g', 'batt'])
        if not output:
            return {}

        data = {}
        lines = output.strip().split('\n')

        if len(lines) > 0:
            match = re.search(r"'([^']+)'", lines[0])
            if match:
                data['power_source'] = match.group(1)

        if len(lines) > 1:
            batt_line = lines[1]

            # Extract percentage
            percent_match = re.search(r'(\d+)%', batt_line)
            if percent_match:
                data['percent'] = int(percent_match.group(1))

            # Extract status
            parts = batt_line.split(';')
            if len(parts) > 1:
                data['status'] = parts[1].strip()

            # Extract time remaining
            if len(parts) > 2:
                time_str = parts[2].strip()
                time_str = re.sub(r'\s*present:.*$', '', time_str)
                if time_str and time_str != '(no estimate)':
                    data['time_remaining'] = time_str

        return data

    def get_system_profiler_power(self) -> Dict[str, Any]:
        """Get power data from system_profiler"""
        output = self.run_command(['system_profiler', 'SPPowerDataType'])
        if not output:
            return {}

        data = {}

        # Extract condition
        match = re.search(r'Condition:\s*(.+)', output)
        if match:
            data['condition'] = match.group(1)
            # Task 1: Battery Service Recommended flag
            # Check if condition indicates service is needed
            condition_lower = match.group(1).lower()
            data['service_recommended'] = (
                'service' in condition_lower or
                'replace' in condition_lower
            )

        # Extract device name (battery model)
        match = re.search(r'Device Name:\s*(.+)', output)
        if match:
            data['device_name'] = match.group(1)

        # Extract serial number
        match = re.search(r'Serial Number:\s*(.+)', output)
        if match:
            data['serial_number'] = match.group(1)

        # Extract firmware version
        match = re.search(r'Firmware Version:\s*(.+)', output)
        if match:
            data['firmware_version'] = match.group(1)

        # Extract charger info
        match = re.search(r'Wattage \(W\):\s*(\d+)', output)
        if match:
            data['wattage'] = int(match.group(1))

        match = re.search(r'Connected:\s*(.+)', output)
        if match:
            data['connected'] = match.group(1)

        # Extract charger Family and ID
        match = re.search(r'Family:\s*(0x[0-9a-fA-F]+)', output)
        if match:
            data['charger_family'] = match.group(1)

        match = re.search(r'^\s+ID:\s*(0x[0-9a-fA-F]+)', output, re.MULTILINE)
        if match:
            data['charger_id'] = match.group(1)
            # Decode to manufacturer/model info
            try:
                charger_id_int = int(match.group(1), 16)
                decoded_id = PowerInfo._decode_charger_id(charger_id_int)
                if decoded_id:
                    data['charger_id_decoded'] = decoded_id
            except ValueError:
                pass

        return data

    def get_system_hardware_info(self) -> Dict[str, Any]:
        """Get system hardware information (Phase 1 Enhancement)

        Collects Mac model, chip, RAM, CPU cores for context.
        """
        data = {}

        # Get hardware data from system_profiler
        output = self.run_command(['system_profiler', 'SPHardwareDataType'])
        if output:
            # Extract Mac model identifier
            match = re.search(r'Model Identifier:\s*(.+)', output)
            if match:
                data['model_identifier'] = match.group(1).strip()

            # Extract chip type
            match = re.search(r'Chip:\s*(.+)', output)
            if match:
                data['chip'] = match.group(1).strip()

            # Extract memory (RAM)
            match = re.search(r'Memory:\s*(.+)', output)
            if match:
                data['memory'] = match.group(1).strip()

        # Get CPU info from sysctl
        cpu_output = self.run_command(['sysctl', '-n', 'hw.physicalcpu'])
        if cpu_output:
            try:
                data['physical_cpu_cores'] = int(cpu_output.strip())
            except ValueError:
                pass

        logical_output = self.run_command(['sysctl', '-n', 'hw.logicalcpu'])
        if logical_output:
            try:
                data['logical_cpu_cores'] = int(logical_output.strip())
            except ValueError:
                pass

        return data

    def get_scheduled_power_events(self) -> Dict[str, Any]:
        """Get scheduled power events (Phase 1 Enhancement)

        Shows wake and sleep events scheduled by the system or apps.
        """
        data = {'wake_events': [], 'sleep_events': []}

        output = self.run_command(['pmset', '-g', 'sched'])
        if not output:
            return data

        # Parse scheduled events
        lines = output.strip().split('\n')
        for line in lines:
            if 'wake at' in line.lower():
                # Extract wake event info
                # Format: " [0]  wake at 10/18/2025 17:12:12 by 'com.apple.alarm...'"
                try:
                    parts = line.split('wake at', 1)
                    if len(parts) == 2:
                        event_info = parts[1].strip()
                        # Split into time and reason
                        if ' by ' in event_info:
                            time_part, reason_part = event_info.split(' by ', 1)
                            reason = reason_part.strip().strip("'\"")
                            # Simplify long bundle identifiers
                            if 'com.apple.' in reason:
                                reason = reason.replace('com.apple.alarm.user-invisible-', '')
                                reason = reason.replace('com.apple.', '')
                            data['wake_events'].append({
                                'time': time_part.strip(),
                                'reason': reason
                            })
                except Exception:
                    pass
            elif 'sleep at' in line.lower():
                # Extract sleep event info
                try:
                    parts = line.split('sleep at', 1)
                    if len(parts) == 2:
                        event_info = parts[1].strip()
                        if ' by ' in event_info:
                            time_part, reason_part = event_info.split(' by ', 1)
                            reason = reason_part.strip().strip("'\"")
                            if 'com.apple.' in reason:
                                reason = reason.replace('com.apple.', '')
                            data['sleep_events'].append({
                                'time': time_part.strip(),
                                'reason': reason
                            })
                except Exception:
                    pass

        return data

    def get_battery_from_ioreg(self) -> Dict[str, Any]:
        """Get detailed battery information from ioreg"""
        ioreg_data = self.get_ioreg_data('AppleSmartBattery', use_archive=True)
        if not ioreg_data or not isinstance(ioreg_data, list) or len(ioreg_data) == 0:
            return {}

        battery = ioreg_data[0]
        data = {}

        # Extract key battery metrics
        if 'CycleCount' in battery:
            data['cycle_count'] = battery['CycleCount']

        # Get design capacity
        design_cap = battery.get('DesignCapacity')
        if design_cap is not None:
            data['design_capacity'] = design_cap

        # Tier 3.4: Nominal Charge Capacity (rated capacity in mAh)
        if 'NominalChargeCapacity' in battery:
            data['nominal_charge_capacity'] = battery['NominalChargeCapacity']

        # Tier 3.1: Current Capacity (real-time remaining capacity in mAh)
        # Use AppleRawCurrentCapacity for actual mAh value (CurrentCapacity is percentage)
        if 'AppleRawCurrentCapacity' in battery:
            data['current_capacity_mah'] = battery['AppleRawCurrentCapacity']
        elif 'CurrentCapacity' in battery and battery['CurrentCapacity'] > 200:
            # Fallback if CurrentCapacity is in mAh (> 200 indicates mAh not percentage)
            data['current_capacity_mah'] = battery['CurrentCapacity']

        # Tier 3.1: Absolute Capacity (may differ from reported capacity)
        # Only include if non-zero
        if 'AbsoluteCapacity' in battery and battery['AbsoluteCapacity'] > 0:
            data['absolute_capacity'] = battery['AbsoluteCapacity']

        # Tier 3.1: At Critical Level (low battery warning flag)
        if 'AtCriticalLevel' in battery:
            data['at_critical_level'] = battery['AtCriticalLevel']

        # Tier 3.1: Cell Count (number of cells in battery pack)
        if 'CellCount' in battery:
            data['cell_count'] = battery['CellCount']

        # Tier 3.1: Battery Chemistry (e.g., "Lithium-ion")
        if 'DeviceChemistry' in battery:
            data['battery_chemistry'] = battery['DeviceChemistry']

        # Tier 3.1: Pack Reserve (reserved capacity not available to user)
        if 'PackReserve' in battery:
            data['pack_reserve'] = battery['PackReserve']
            # Add human-readable format
            data['pack_reserve_decoded'] = f"{battery['PackReserve']} mAh (reserved)"

        # Gas Gauge Firmware Version
        if 'GasGaugeFirmwareVersion' in battery:
            data['gas_gauge_fw_version'] = battery['GasGaugeFirmwareVersion']
            data['gas_gauge_fw_decoded'] = f"v{battery['GasGaugeFirmwareVersion']}"

        # Tier 3.1: Battery Install Date
        if 'BatteryInstallDate' in battery:
            data['battery_install_date'] = battery['BatteryInstallDate']

        # Get Full Charge Capacity (FCC) - actual mAh value
        # Try multiple keys in order of preference
        fcc = (battery.get('AppleRawMaxCapacity') or
               battery.get('FullChargeCapacity') or
               battery.get('AppleRawFullChargeCapacity') or
               battery.get('NominalChargeCapacity'))

        if fcc is not None and fcc > 200:  # Should be in mAh, not percentage
            data['fcc_mah'] = fcc

        # MaxCapacity can be percentage or absolute value (mAh)
        max_cap = battery.get('MaxCapacity')
        if max_cap is not None:
            data['max_capacity_raw'] = max_cap

        if 'Voltage' in battery:
            data['voltage_mv'] = battery['Voltage']
            data['voltage_v'] = battery['Voltage'] / 1000.0

        if 'Amperage' in battery:
            # Handle potential overflow values
            amp = battery['Amperage']
            if amp >= 2**31:
                amp -= 2**32
            elif amp >= 2**63:
                amp -= 2**64
            data['amperage_ma'] = amp
            data['amperage_a'] = amp / 1000.0

            # Calculate battery charge power (V × I)
            if 'voltage_mv' in data and amp > 0:  # Only when charging (positive current)
                power_w = (data['voltage_mv'] * amp) / 1000000.0
                data['battery_charge_power_w'] = power_w

        # Tier 3.1: Instantaneous Amperage (vs average amperage)
        if 'InstantAmperage' in battery:
            inst_amp = battery['InstantAmperage']
            # Handle potential overflow values
            if inst_amp >= 2**31:
                inst_amp -= 2**32
            elif inst_amp >= 2**63:
                inst_amp -= 2**64
            data['instant_amperage_ma'] = inst_amp
            data['instant_amperage_a'] = inst_amp / 1000.0

        # Tier 3.4: Filtered Current (smoothed amperage reading)
        if 'BatteryData' in battery and isinstance(battery['BatteryData'],
                                                    dict):
            batt_data_fc = battery['BatteryData']
            if 'FilteredCurrent' in batt_data_fc:
                filt_cur = batt_data_fc['FilteredCurrent']
                # Handle potential overflow values
                if filt_cur >= 2**31:
                    filt_cur -= 2**32
                elif filt_cur >= 2**63:
                    filt_cur -= 2**64
                data['filtered_current_ma'] = filt_cur
                data['filtered_current_a'] = filt_cur / 1000.0

        if 'Temperature' in battery:
            # Convert from decikelvin to Celsius
            temp = battery['Temperature']
            data['temp_c'] = (temp - 2731.5) / 10.0

        if 'IsCharging' in battery:
            data['is_charging'] = battery['IsCharging']

        if 'ExternalConnected' in battery:
            data['external_connected'] = battery['ExternalConnected']

        # Time remaining (in minutes)
        if 'TimeRemaining' in battery:
            time_min = battery['TimeRemaining']
            # Only use if it's a reasonable value (not 65535 or other sentinel values)
            if time_min > 0 and time_min < 10000:
                data['time_remaining_min'] = time_min

        # Average time to full (when charging)
        if 'AvgTimeToFull' in battery:
            time_min = battery['AvgTimeToFull']
            data['avg_time_to_full_min'] = time_min
            # Decode to human-readable
            decoded_time = PowerInfo._decode_time_minutes(time_min)
            if decoded_time:
                data['avg_time_to_full_decoded'] = decoded_time

        # Average time to empty (when discharging)
        if 'AvgTimeToEmpty' in battery:
            time_min = battery['AvgTimeToEmpty']
            data['avg_time_to_empty_min'] = time_min
            # Decode to human-readable (handles 0xFFFF special case)
            decoded_time = PowerInfo._decode_time_minutes(time_min)
            if decoded_time:
                data['avg_time_to_empty_decoded'] = decoded_time

        # Calculate health percentage
        # Use FCC if available, otherwise fall back to MaxCapacity
        if 'fcc_mah' in data and 'design_capacity' in data and data['design_capacity'] > 0:
            # Calculate health from FCC
            data['health_percent'] = int((data['fcc_mah'] * 100) / data['design_capacity'])
        elif 'max_capacity_raw' in data and 'design_capacity' in data:
            # Fall back to MaxCapacity
            max_cap = data['max_capacity_raw']
            design_cap = data['design_capacity']

            if max_cap <= 100:
                # Already a percentage
                data['health_percent'] = int(max_cap)
                data['max_capacity'] = max_cap
            elif design_cap > 0:
                # Absolute capacity in mAh
                data['health_percent'] = int((max_cap * 100) / design_cap)
                data['max_capacity'] = max_cap
            else:
                data['max_capacity'] = max_cap

        # Adapter details (if available with sudo)
        if self.use_sudo and 'AdapterDetails' in battery:
            adapter = battery['AdapterDetails']
            if 'Watts' in adapter:
                data['adapter_watts'] = adapter['Watts']
            if 'AdapterVoltage' in adapter:
                data['adapter_voltage_mv'] = adapter['AdapterVoltage']
            if 'Current' in adapter:
                data['adapter_current_ma'] = adapter['Current']
            if 'Description' in adapter:
                data['adapter_description'] = adapter['Description']
            # IsWireless: Distinguish MagSafe wireless vs USB-C wired
            if 'IsWireless' in adapter:
                data['is_wireless_charging'] = adapter['IsWireless']

            # Active Voltage Profile Index (UsbHvcHvcIndex)
            # This is an integer index into the UsbHvcMenu array that
            # indicates which voltage/current profile is currently active
            if 'UsbHvcHvcIndex' in adapter:
                profile_index = adapter['UsbHvcHvcIndex']
                data['active_voltage_profile_index'] = profile_index

                # Cross-reference with UsbHvcMenu to get the actual profile
                if 'UsbHvcMenu' in adapter:
                    menu = adapter['UsbHvcMenu']
                    if isinstance(menu, list) and 0 <= profile_index < len(menu):
                        profile = menu[profile_index]
                        # Extract voltage (mV), current (mA), and power (W)
                        # from the active profile
                        if 'MaxVoltage' in profile and 'MaxCurrent' in profile:
                            data['active_profile_voltage_mv'] = profile['MaxVoltage']
                            data['active_profile_current_ma'] = profile['MaxCurrent']
                            # Calculate power if not directly available
                            if 'Power' in profile:
                                data['active_profile_power_w'] = profile['Power']
                            else:
                                # Calculate: (mV * mA) / 1,000,000 = W
                                power_w = (profile['MaxVoltage'] * profile['MaxCurrent']) / 1000000.0
                                data['active_profile_power_w'] = int(power_w)

        # ChargerData (if available with sudo)
        if self.use_sudo and 'ChargerData' in battery:
            charger_data = battery['ChargerData']
            if 'NotChargingReason' in charger_data:
                data['not_charging_reason'] = charger_data['NotChargingReason']

        # Tier 3.1: Optimal Charge Limit (80% limit enabled on macOS Ventura+)
        if 'ChargeLimit' in battery or 'BatteryChargeLimit' in battery:
            data['charge_limit'] = battery.get('ChargeLimit') or battery.get('BatteryChargeLimit')

        # Tier 3.1: Battery Charge Inhibit (charging inhibited by system)
        if 'BatteryInhibitCharge' in battery:
            data['battery_inhibit_charge'] = battery['BatteryInhibitCharge']

        # Tier 3.1: Optimized Battery Charging (macOS Catalina+)
        if 'OptimizedBatteryCharging' in battery or 'BatteryHealthData' in battery:
            obc_enabled = battery.get('OptimizedBatteryCharging', False)
            data['optimized_battery_charging'] = obc_enabled
            # Check if currently in optimized charging mode
            if 'BatteryHealthData' in battery:
                health_data = battery['BatteryHealthData']
                if isinstance(health_data, dict):
                    if 'OptimizedChargingEngaged' in health_data:
                        data['optimized_charging_engaged'] = health_data['OptimizedChargingEngaged']

        # Tier 3.1: Fast/Trickle Charging Detection
        if 'battery_charge_power_w' in data:
            charge_power = data['battery_charge_power_w']
            # Fast charging: > 20W
            if charge_power > 20:
                data['fast_charging'] = True
            # Trickle charging: < 5W and charging
            elif charge_power > 0 and charge_power < 5:
                data['trickle_charging'] = True

        # Tier 3.1: Charging Efficiency (Battery Power / Adapter Power)
        if 'battery_charge_power_w' in data and 'adapter_watts' in data:
            if data['adapter_watts'] > 0:
                efficiency = (data['battery_charge_power_w'] / data['adapter_watts']) * 100.0
                data['charging_efficiency_pct'] = efficiency

        # Tier 3.1: Charging Cycles Remaining (estimate)
        if 'cycle_count' in data and 'health_percent' in data:
            # Assume battery good until 80% health, typical 1000 cycle lifespan
            current_cycles = data['cycle_count']
            current_health = data['health_percent']
            # Estimate cycles to 80% health
            if current_health > 80:
                # Linear degradation model: health loss per cycle
                health_loss_per_cycle = (100 - current_health) / current_cycles if current_cycles > 0 else 0
                if health_loss_per_cycle > 0:
                    cycles_to_80_pct = (current_health - 80) / health_loss_per_cycle
                    data['estimated_cycles_remaining'] = int(cycles_to_80_pct)

        # Tier 3.2: Charging Analysis (8 features)
        if self.use_sudo:
            # Charging Voltage (target vs actual)
            if 'ChargingVoltage' in battery:
                data['charging_voltage_mv'] = battery['ChargingVoltage']
                data['charging_voltage_v'] = battery['ChargingVoltage'] / 1000.0

            # Max Charge Current
            if 'MaxChargeCurrent' in battery:
                data['max_charge_current_ma'] = battery['MaxChargeCurrent']
                data['max_charge_current_a'] = battery['MaxChargeCurrent'] / 1000.0

            # External Charge Capable
            if 'ExternalChargeCapable' in battery:
                data['external_charge_capable'] = battery['ExternalChargeCapable']

            # Charger Configuration
            if 'ChargerConfiguration' in battery:
                data['charger_configuration'] = battery['ChargerConfiguration']

            # Slow Charging Reason (from BatteryData)
            if 'BatteryData' in battery and isinstance(battery['BatteryData'], dict):
                batt_data = battery['BatteryData']
                if 'SlowChargingReason' in batt_data:
                    data['slow_charging_reason'] = batt_data['SlowChargingReason']
                    # Decode to human-readable
                    decoded_slow = PowerInfo._decode_slow_charging_reason(batt_data['SlowChargingReason'])
                    if decoded_slow:
                        data['slow_charging_reason_decoded'] = decoded_slow

                # Time Charging Thermally Limited
                if 'TimeChargingThermallyLimited' in batt_data:
                    data['time_charging_thermally_limited'] = batt_data['TimeChargingThermallyLimited']

                # Tier 3.3A: Cell-Level Diagnostics
                if 'CellVoltage' in batt_data:
                    data['cell_voltages_mv'] = batt_data['CellVoltage']
                    # Calculate cell imbalance
                    if isinstance(batt_data['CellVoltage'], list) and len(batt_data['CellVoltage']) > 1:
                        voltages = batt_data['CellVoltage']
                        max_v = max(voltages)
                        min_v = min(voltages)
                        data['cell_voltage_delta_mv'] = max_v - min_v
                        # Imbalance warning if delta > 50mV
                        if (max_v - min_v) > 50:
                            data['cell_imbalance_warning'] = True

                # Tier 3.3B: Battery Reliability Metrics
                if 'BatteryHealthMetric' in batt_data:
                    data['battery_health_metric'] = batt_data['BatteryHealthMetric']
                if 'BatteryRsenseOpenCount' in batt_data:
                    data['battery_rsense_open_count'] = batt_data['BatteryRsenseOpenCount']
                if 'DataFlashWriteCount' in batt_data:
                    data['data_flash_write_count'] = batt_data['DataFlashWriteCount']
                if 'QmaxDisqualificationReason' in batt_data:
                    data['qmax_disqualification_reason'] = batt_data['QmaxDisqualificationReason']

                # Tier 3.3C: Manufacturing & Provenance
                if 'ManufactureDate' in batt_data:
                    data['manufacture_date_raw'] = batt_data['ManufactureDate']
                    # Decode to human-readable format
                    decoded_date = PowerInfo.decode_manufacture_date(batt_data['ManufactureDate'])
                    if decoded_date:
                        data['manufacture_date'] = decoded_date
                if 'DateOfFirstUse' in batt_data:
                    data['date_of_first_use'] = batt_data['DateOfFirstUse']
                if 'ChemID' in batt_data:
                    data['chem_id'] = batt_data['ChemID']
                    # Decode to chemistry name
                    decoded_chem = PowerInfo._decode_chem_id(batt_data['ChemID'])
                    if decoded_chem:
                        data['chem_id_decoded'] = decoded_chem

                # Tier 3.3D: SOC & Charge Analysis
                if 'StateOfCharge' in batt_data:
                    data['gauge_soc_pct'] = batt_data['StateOfCharge']
                if 'DailyMaxSoc' in batt_data:
                    data['daily_max_soc'] = batt_data['DailyMaxSoc']
                if 'DailyMinSoc' in batt_data:
                    data['daily_min_soc'] = batt_data['DailyMinSoc']
                if 'TrueRemainingCapacity' in batt_data:
                    data['true_remaining_capacity'] = batt_data['TrueRemainingCapacity']

                # Tier 3.3F: Advanced Gauge Data
                if 'WeightedRa' in batt_data:
                    data['weighted_ra'] = batt_data['WeightedRa']
                if 'ISS' in batt_data:
                    data['gauge_iss'] = batt_data['ISS']
                if 'RSS' in batt_data:
                    data['gauge_rss'] = batt_data['RSS']
                if 'Qmax' in batt_data:
                    data['gauge_qmax'] = batt_data['Qmax']
                if 'DOD0' in batt_data:
                    data['gauge_dod0'] = batt_data['DOD0']
                if 'GaugeFlagRaw' in batt_data:
                    data['gauge_flag_raw'] = batt_data['GaugeFlagRaw']
                    # Decode to human-readable
                    decoded_flags = PowerInfo._decode_gauge_flag_raw(batt_data['GaugeFlagRaw'])
                    if decoded_flags:
                        data['gauge_flag_decoded'] = decoded_flags
                if 'MiscStatus' in batt_data:
                    data['misc_status_raw'] = batt_data['MiscStatus']
                    # Decode to human-readable
                    decoded_status = PowerInfo._decode_misc_status(batt_data['MiscStatus'])
                    if decoded_status:
                        data['misc_status_decoded'] = decoded_status

                # Tier 3.4: Charge Accumulated (total charge accumulated)
                if 'ChargeAccum' in batt_data:
                    data['charge_accum_mah'] = batt_data['ChargeAccum']

        # Wait/Timing fields (top-level)
        if 'PostChargeWaitSeconds' in battery:
            data['post_charge_wait_seconds'] = battery['PostChargeWaitSeconds']
            # Decode to human-readable
            decoded_wait = PowerInfo._decode_wait_seconds(battery['PostChargeWaitSeconds'])
            if decoded_wait:
                data['post_charge_wait_decoded'] = decoded_wait
        if 'PostDischargeWaitSeconds' in battery:
            data['post_discharge_wait_seconds'] = battery['PostDischargeWaitSeconds']
            # Decode to human-readable
            decoded_wait = PowerInfo._decode_wait_seconds(battery['PostDischargeWaitSeconds'])
            if decoded_wait:
                data['post_discharge_wait_decoded'] = decoded_wait
        if 'BatteryInvalidWakeSeconds' in battery:
            data['battery_invalid_wake_seconds'] = battery['BatteryInvalidWakeSeconds']
            # Decode to human-readable
            decoded_wake = PowerInfo._decode_wait_seconds(battery['BatteryInvalidWakeSeconds'])
            if decoded_wake:
                data['battery_invalid_wake_decoded'] = decoded_wake

        # Tier 3.3B: Battery Reliability Metrics (top-level fields)
        if 'BatteryCellDisconnectCount' in battery:
            data['battery_cell_disconnect_count'] = battery['BatteryCellDisconnectCount']
        if 'PermanentFailureStatus' in battery:
            data['permanent_failure_status'] = battery['PermanentFailureStatus']
            # Decode to human-readable
            decoded_failure = PowerInfo._decode_permanent_failure_status(battery['PermanentFailureStatus'])
            if decoded_failure:
                data['permanent_failure_decoded'] = decoded_failure

        # Tier 3.3C: Manufacturing Data (binary blob)
        if 'ManufacturerData' in battery:
            data['manufacturer_data_raw'] = battery['ManufacturerData']
            # Decode manufacturer details
            mfg_details = self.decode_manufacturer_data(battery['ManufacturerData'])
            if mfg_details:
                if 'model' in mfg_details:
                    data['battery_model_mfg'] = mfg_details['model']
                if 'revision' in mfg_details:
                    data['battery_revision_mfg'] = mfg_details['revision']
                if 'manufacturer' in mfg_details:
                    data['battery_manufacturer'] = mfg_details['manufacturer']

        # Tier 3.3C: Design Cycle Count (expected lifespan)
        if 'DesignCycleCount9C' in battery:
            data['design_cycle_count'] = battery['DesignCycleCount9C']
            # Add human-readable format
            data['design_cycle_count_decoded'] = f"{battery['DesignCycleCount9C']} cycles (design lifespan)"

        # Tier 3.3D: Carrier Mode (Shipping Mode)
        if 'CarrierMode' in battery and isinstance(battery['CarrierMode'], dict):
            carrier = battery['CarrierMode']
            if 'CarrierModeStatus' in carrier:
                data['carrier_mode_status'] = carrier['CarrierModeStatus']
            if 'CarrierModeHighVoltage' in carrier:
                data['carrier_mode_high_voltage_mv'] = carrier['CarrierModeHighVoltage']
            if 'CarrierModeLowVoltage' in carrier:
                data['carrier_mode_low_voltage_mv'] = carrier['CarrierModeLowVoltage']
            # Store full dict and decode
            data['carrier_mode'] = carrier
            decoded_carrier = PowerInfo._decode_carrier_mode(carrier)
            if decoded_carrier:
                data['carrier_mode_decoded'] = decoded_carrier

        # Tier 3.3E: Power Telemetry - Lifetime Stats
        if 'PowerTelemetryData' in battery and isinstance(battery['PowerTelemetryData'], dict):
            ptd = battery['PowerTelemetryData']
            if 'AccumulatedSystemEnergyConsumed' in ptd:
                # Convert to kWh (value is in some unit, need to determine)
                data['accumulated_system_energy'] = ptd['AccumulatedSystemEnergyConsumed']
            if 'AccumulatedBatteryDischarge' in ptd:
                data['accumulated_battery_discharge'] = ptd['AccumulatedBatteryDischarge']
            if 'AccumulatedBatteryPower' in ptd:
                data['accumulated_battery_power'] = ptd['AccumulatedBatteryPower']
            if 'AccumulatedAdapterEfficiencyLoss' in ptd:
                data['accumulated_adapter_efficiency_loss'] = ptd['AccumulatedAdapterEfficiencyLoss']

            # Live/Real-time Power Flow Metrics (convert from mW to W)
            if 'SystemPowerIn' in ptd:
                data['system_power_in_w'] = ptd['SystemPowerIn'] / 1000.0
            if 'BatteryPower' in ptd:
                data['battery_power_w'] = ptd['BatteryPower'] / 1000.0
            if 'SystemLoad' in ptd:
                data['system_load_w'] = ptd['SystemLoad'] / 1000.0
            if 'AdapterEfficiencyLoss' in ptd:
                data['adapter_efficiency_loss_w'] = ptd['AdapterEfficiencyLoss'] / 1000.0

            # Phase 1 Enhancements: Additional PowerTelemetryData metrics
            if 'WallEnergyEstimate' in ptd:
                # Real-time AC wall power estimate (mW)
                data['wall_energy_estimate_w'] = ptd['WallEnergyEstimate'] / 1000.0
            if 'SystemCurrentIn' in ptd:
                # Adapter current in real-time (mA)
                data['system_current_in_ma'] = ptd['SystemCurrentIn']
                data['system_current_in_a'] = ptd['SystemCurrentIn'] / 1000.0
            if 'SystemVoltageIn' in ptd:
                # Adapter voltage in real-time (mV)
                data['system_voltage_in_mv'] = ptd['SystemVoltageIn']
                data['system_voltage_in_v'] = ptd['SystemVoltageIn'] / 1000.0
            if 'SystemEnergyConsumed' in ptd:
                # Instant system energy consumption (mWh or similar)
                data['system_energy_consumed'] = ptd['SystemEnergyConsumed']
            if 'AccumulatedWallEnergyEstimate' in ptd:
                # Lifetime wall energy estimate
                data['accumulated_wall_energy'] = ptd['AccumulatedWallEnergyEstimate']

        # Tier 3.3F: Virtual Temperature
        if 'VirtualTemperature' in battery:
            # Also in decikelvin
            temp = battery['VirtualTemperature']
            data['virtual_temp_c'] = (temp - 2731.5) / 10.0

        # Tier 3.3G: Charger/Adapter Enhancements
        if 'BestAdapterIndex' in battery:
            data['best_adapter_index'] = battery['BestAdapterIndex']

        # ChargerInhibitReason from ChargerData
        if 'ChargerData' in battery and isinstance(battery['ChargerData'], dict):
            cdata = battery['ChargerData']
            if 'ChargerInhibitReason' in cdata:
                data['charger_inhibit_reason'] = cdata['ChargerInhibitReason']
            if 'ChargerStatus' in cdata:
                data['charger_status_raw'] = cdata['ChargerStatus']

            # Maximum System Power (from adapter or charger data)
            if 'AdapterDetails' in battery:
                adapter = battery['AdapterDetails']
                if 'MaxPower' in adapter:
                    data['max_system_power_w'] = adapter['MaxPower']
                elif 'MaximumPower' in adapter:
                    data['max_system_power_w'] = adapter['MaximumPower']

            # Charger Temperature (if available from PMU charger)
            if 'Temperature' in battery and 'ChargerData' in battery:
                # This might be charger temp, not battery temp
                # Need to distinguish - for now, skip to avoid confusion
                pass

        # Lifetime statistics (if available with sudo)
        # LifetimeData can be at top level or inside BatteryData
        lifetime = None
        if self.use_sudo:
            if 'LifetimeData' in battery:
                lifetime = battery['LifetimeData']
            elif 'BatteryData' in battery and isinstance(battery['BatteryData'], dict):
                if 'LifetimeData' in battery['BatteryData']:
                    lifetime = battery['BatteryData']['LifetimeData']

        if lifetime:
            if 'TotalOperatingTime' in lifetime:
                minutes = lifetime['TotalOperatingTime']
                data['total_operating_time_min'] = minutes
                data['total_operating_time_hrs'] = minutes / 60.0

            if 'MaximumTemperature' in lifetime:
                data['max_temp_c'] = lifetime['MaximumTemperature']

            if 'MinimumTemperature' in lifetime:
                data['min_temp_c'] = lifetime['MinimumTemperature']

            if 'AverageTemperature' in lifetime:
                # Average temperature is in decikelvin format (tenths of a degree)
                data['avg_temp_c'] = lifetime['AverageTemperature'] / 10.0

            # Tier 3.4: Cycle Count at Last Qmax Calibration
            if 'CycleCountLastQmax' in lifetime:
                data['cycle_count_last_qmax'] = lifetime['CycleCountLastQmax']
                # Calculate cycles since last calibration
                if 'cycle_count' in data:
                    cycles_since = data['cycle_count'] - \
                        lifetime['CycleCountLastQmax']
                    data['cycles_since_qmax_cal'] = cycles_since

        return data

    def get_powermetrics(self) -> Dict[str, Any]:
        """Get power metrics (requires sudo)

        Tier 3.1: Includes Thermal Pressure Level (Normal/Nominal, Light, Moderate, Heavy)

        Tier 3.2: Extended to include SoC Power, Combined Power, Package Power,
        Disk Power, Network Power, and Peripheral Power.

        Note: DRAM Power may not be available on all systems or in all states.
        It will default to 0.0W if not reported by powermetrics.
        """
        if not self.use_sudo:
            return {}

        output = self.run_command(['powermetrics', '-i', '1000', '-n', '1'])
        if not output:
            return {}

        data = {}

        # Parse power values
        for line in output.split('\n'):
            if 'CPU Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['cpu_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif 'GPU Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['gpu_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif 'ANE Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['ane_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif 'DRAM Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['dram_power_w'] = val / 1000.0 if unit.startswith('m') else val

            # Tier 3.2: Advanced Power Metrics
            elif 'SoC Power' in line or 'SOC Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['soc_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif 'Combined Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['combined_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif 'Package Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['package_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif 'Disk' in line and 'Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['disk_power_w'] = val / 1000.0 if unit.startswith('m') else val

            elif ('Network' in line or 'WiFi' in line or 'Bluetooth' in line) and 'Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    # Accumulate network power (WiFi + Bluetooth if separate)
                    current_network = data.get('network_power_w', 0.0)
                    data['network_power_w'] = current_network + (val / 1000.0 if unit.startswith('m') else val)

            elif 'Peripheral' in line and 'Power' in line:
                match = re.search(r'([\d.]+)\s*([mM]?[wW])', line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2).lower()
                    data['peripheral_power_w'] = val / 1000.0 if unit.startswith('m') else val

            # Tier 3.1: Thermal Pressure Level
            # Parse thermal pressure from powermetrics thermal sampler output
            # Example: "Thermal pressure: Nominal" or "Thermal pressure: Light"
            # Possible values: Normal, Nominal, Light, Moderate, Heavy
            elif 'Thermal pressure:' in line:
                match = re.search(r'Thermal pressure:\s*(\w+)', line)
                if match:
                    pressure = match.group(1)
                    data['thermal_pressure'] = pressure

        # Tier 3.2: Calculate derived metrics
        # Peak Power Draw - max of all component powers
        all_powers = [
            data.get('cpu_power_w', 0.0),
            data.get('gpu_power_w', 0.0),
            data.get('ane_power_w', 0.0),
            data.get('dram_power_w', 0.0),
            data.get('disk_power_w', 0.0),
            data.get('network_power_w', 0.0),
            data.get('peripheral_power_w', 0.0)
        ]
        if all_powers and any(p > 0 for p in all_powers):
            data['peak_component_power_w'] = max(all_powers)

        # Idle Power Baseline - estimate based on low total power
        total_power = sum(all_powers)
        if total_power > 0 and total_power < 5.0:  # If very low power, assume near idle
            data['idle_power_estimate_w'] = total_power

        # Default thermal pressure to Nominal if not found (system running cool)
        if 'thermal_pressure' not in data:
            data['thermal_pressure'] = 'Nominal'

        return data

    def get_display_brightness(self) -> Optional[float]:
        """Get display brightness as a percentage (0-100)"""
        # Try to get brightness from ioreg
        output = self.run_command(['ioreg', '-l'])
        if not output:
            return None

        # Look for IODisplayParameters.brightness
        # Format: "brightness"={"min"=0,"max"=65536,"value"=32768}
        match = re.search(r'"brightness"=\{"min"=\d+,"max"=(\d+),"value"=(\d+)\}', output)
        if match:
            max_val = int(match.group(1))
            value = int(match.group(2))
            if max_val > 0:
                return (value / max_val) * 100.0

        return None

    def get_power_management_settings(self) -> Dict[str, Any]:
        """Get power management settings from pmset

        Tier 3.1 Features:
        - Power Assertions (what's preventing sleep)
        - Low Power Mode status
        - Hibernation Mode setting
        - Standby Delay
        - Wake on LAN status

        Tier 3.2 Features (System Power History):
        - Power Nap status
        - Auto Power Off Delay
        - Screen Energy Saver settings
        - Power Source History (recent AC/Battery transitions)
        - Sleep/Wake History
        """
        data = {}

        # Get pmset -g settings
        output = self.run_command(['pmset', '-g', 'custom'])
        if output:
            # Hibernation mode
            match = re.search(r'hibernatemode\s+(\d+)', output)
            if match:
                data['hibernation_mode'] = int(match.group(1))

            # Standby delay (in seconds)
            match = re.search(r'standbydelayhigh\s+(\d+)', output)
            if match:
                data['standby_delay_high'] = int(match.group(1))
            match = re.search(r'standbydelaylow\s+(\d+)', output)
            if match:
                data['standby_delay_low'] = int(match.group(1))

            # Wake on LAN
            match = re.search(r'womp\s+(\d+)', output)
            if match:
                data['wake_on_lan'] = match.group(1) == '1'

            # Low Power Mode (macOS 12+)
            match = re.search(r'lowpowermode\s+(\d+)', output)
            if match:
                data['low_power_mode'] = match.group(1) == '1'

            # Tier 3.2: Power Nap
            match = re.search(r'powernap\s+(\d+)', output)
            if match:
                data['power_nap'] = match.group(1) == '1'

            # Tier 3.2: Auto Power Off Delay
            match = re.search(r'autopoweroffdelay\s+(\d+)', output)
            if match:
                data['auto_power_off_delay'] = int(match.group(1))

            # Tier 3.2: Display Sleep Timer
            match = re.search(r'displaysleep\s+(\d+)', output)
            if match:
                data['display_sleep_minutes'] = int(match.group(1))

        # Tier 3.1: Power Assertions (what's preventing sleep)
        assertions_output = self.run_command(['pmset', '-g', 'assertions'])
        if assertions_output:
            assertions = []
            # Look for active assertions
            for line in assertions_output.split('\n'):
                # Match lines like: "PreventUserIdleSystemSleep named: "UserIsActive""
                match = re.search(r'(Prevent\w+)\s+named:\s+"([^"]+)"', line)
                if match:
                    assertions.append({'type': match.group(1), 'name': match.group(2)})
            if assertions:
                data['power_assertions'] = assertions

        # Tier 3.2: Power Source History and Sleep/Wake History
        # Parse pmset -g log for recent events (last hour to keep it fast)
        log_output = self.run_command(['pmset', '-g', 'log'])
        if log_output:
            power_source_changes = []
            sleep_wake_events = []

            lines = log_output.split('\n')[-200:]  # Last 200 lines for performance

            for line in lines:
                # Power source transitions: "Using AC" or "Using Batt"
                if 'Using AC' in line or 'Using Batt' in line:
                    # Extract timestamp and event
                    match = re.search(r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})', line)
                    if match:
                        timestamp = match.group(1)
                        source = 'AC Power' if 'Using AC' in line else 'Battery'
                        power_source_changes.append({'timestamp': timestamp, 'source': source})

                # Sleep/Wake events
                elif 'Sleep' in line or 'Wake' in line or 'DarkWake' in line:
                    match = re.search(r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})', line)
                    if match:
                        timestamp = match.group(1)
                        event_type = 'Sleep' if 'Sleep' in line else ('DarkWake' if 'DarkWake' in line else 'Wake')
                        sleep_wake_events.append({'timestamp': timestamp, 'event': event_type})

            # Keep last 5 of each type
            if power_source_changes:
                data['power_source_history'] = power_source_changes[-5:]
            if sleep_wake_events:
                data['sleep_wake_history'] = sleep_wake_events[-5:]

        return data

    def estimate_display_power(self, brightness_percent: Optional[float]) -> float:
        """Estimate display backlight power consumption based on brightness

        Typical MacBook display power consumption:
        - 13-inch: ~2-4W at 100% brightness
        - 14-inch: ~3-5W at 100% brightness
        - 16-inch: ~4-6W at 100% brightness

        Using conservative estimate of 5W at 100% brightness.
        Power scales roughly linearly with brightness.
        """
        if brightness_percent is None or brightness_percent <= 0:
            return 0.0

        # Conservative estimate: 5W at 100% brightness
        max_display_power = 5.0
        return (brightness_percent / 100.0) * max_display_power

    def get_usb_port_limits(self) -> Dict[str, Any]:
        """Get USB port current limits from ioreg"""
        ioreg_data = self.get_ioreg_data('AppleUSBHostPort', use_archive=True)
        if not ioreg_data or not isinstance(ioreg_data, list) or len(ioreg_data) == 0:
            return {}

        data = {}
        # Get from first port (usually they're all the same)
        port = ioreg_data[0]

        if 'kUSBWakePortCurrentLimit' in port:
            data['wake_current_ma'] = port['kUSBWakePortCurrentLimit']

        if 'kUSBSleepPortCurrentLimit' in port:
            data['sleep_current_ma'] = port['kUSBSleepPortCurrentLimit']

        return data

    def decode_pdo(self, pdo: int) -> Optional[Dict[str, Any]]:
        """Decode a 32-bit USB-C PD Power Data Object (PDO)

        Returns dict with voltage_v, current_a, power_w, and pdo_type
        """
        if pdo == 0:
            return None

        # Extract PDO type from bits 30-31
        pdo_type = (pdo >> 30) & 0x3

        if pdo_type == 0:  # Fixed Supply PDO
            # Voltage in 50mV units (bits 10-19)
            voltage_mv = ((pdo >> 10) & 0x3FF) * 50
            # Current in 10mA units (bits 0-9)
            current_ma = (pdo & 0x3FF) * 10

            return {
                'pdo_type': 'Fixed',
                'voltage_v': voltage_mv / 1000.0,
                'current_a': current_ma / 1000.0,
                'power_w': (voltage_mv * current_ma) / 1000000.0,
                'voltage_mv': voltage_mv,
                'current_ma': current_ma
            }
        elif pdo_type == 3:  # Augmented Power Data Object (APDO) - PPS
            # Max voltage in 100mV units (bits 17-24)
            max_voltage_mv = ((pdo >> 17) & 0xFF) * 100
            # Min voltage in 100mV units (bits 8-15)
            min_voltage_mv = ((pdo >> 8) & 0xFF) * 100
            # Max current in 50mA units (bits 0-6)
            max_current_ma = (pdo & 0x7F) * 50

            return {
                'pdo_type': 'PPS',
                'min_voltage_v': min_voltage_mv / 1000.0,
                'max_voltage_v': max_voltage_mv / 1000.0,
                'current_a': max_current_ma / 1000.0,
                'voltage_mv': max_voltage_mv,
                'current_ma': max_current_ma
            }

        # Other PDO types not commonly used
        return {'pdo_type': f'Type {pdo_type}', 'raw': pdo}

    def decode_rdo(self, rdo: int) -> Dict[str, Any]:
        """Decode a 32-bit USB-C PD Request Data Object (RDO)

        Returns dict with operating/max current and object position
        """
        if rdo == 0:
            return {}

        # Object position (bits 28-30) - which PDO is being requested
        obj_pos = (rdo >> 28) & 0x7

        # Operating current in 10mA units (bits 10-19)
        operating_current_ma = ((rdo >> 10) & 0x3FF) * 10

        # Max/Min current in 10mA units (bits 0-9)
        max_current_ma = (rdo & 0x3FF) * 10

        return {
            'object_position': obj_pos,
            'operating_current_ma': operating_current_ma,
            'operating_current_a': operating_current_ma / 1000.0,
            'max_current_ma': max_current_ma,
            'max_current_a': max_current_ma / 1000.0,
            'rdo_hex': f'0x{rdo:08X}'
        }

    def get_usbc_pd_info(self) -> Dict[str, Any]:
        """Get USB-C Power Delivery information from ioreg"""
        if not self.use_sudo:
            return {}

        ioreg_data = self.get_ioreg_data('AppleSmartBattery', use_archive=True)
        if not ioreg_data or not isinstance(ioreg_data, list) or len(ioreg_data) == 0:
            return {}

        battery = ioreg_data[0]
        data = {}

        # Find the active port (the one with a non-zero RDO and preferably non-zero MaxPower)
        port_info = battery.get('PortControllerInfo', [])
        fed_details = battery.get('FedDetails', [])

        active_port_idx = None
        fallback_port_idx = None

        for idx, port in enumerate(port_info):
            rdo = port.get('PortControllerActiveContractRdo', 0)
            max_power = port.get('PortControllerMaxPower', 0)

            if rdo != 0:
                # Prefer port with non-zero MaxPower
                if max_power > 0:
                    active_port_idx = idx
                    break
                # Keep first non-zero RDO as fallback
                elif fallback_port_idx is None:
                    fallback_port_idx = idx

        # Use port with MaxPower, or fallback to first with RDO
        if active_port_idx is None:
            active_port_idx = fallback_port_idx

        if active_port_idx is None:
            return {}

        active_port = port_info[active_port_idx]

        # Get PD version and roles from FedDetails
        if active_port_idx < len(fed_details):
            fed = fed_details[active_port_idx]

            # PD Spec Revision (0=1.0, 1=2.0, 2=3.0, 3=3.1)
            pd_rev = fed.get('FedPdSpecRevision', 0)
            pd_version_map = {0: '1.0', 1: '2.0', 2: '3.0', 3: '3.1'}
            data['pd_version'] = pd_version_map.get(pd_rev, f'{pd_rev}')

            # Power Role (0=Sink, 1=Source)
            power_role = fed.get('FedPortPowerRole', 0)
            data['power_role'] = 'Sink' if power_role == 0 else 'Source'

            # Data Role - try to get from FedDetails or infer from DualRolePower
            # In USB-C PD: UFP (Upstream Facing Port) or DFP (Downstream Facing Port)
            dual_role = fed.get('FedDualRolePower', 0)
            if dual_role == 1:
                # Device supports both UFP and DFP, typically in DRP mode
                # When acting as Sink, usually UFP
                data['data_role'] = 'UFP' if power_role == 0 else 'DFP'
            else:
                # Fixed role device
                data['data_role'] = 'UFP' if power_role == 0 else 'DFP'

        # Port Controller Info
        if 'PortControllerFwVersion' in active_port:
            fw_ver = active_port['PortControllerFwVersion']
            # Convert to version format (e.g., 3.6.0)
            major = (fw_ver >> 16) & 0xFF
            minor = (fw_ver >> 8) & 0xFF
            patch = fw_ver & 0xFF
            data['port_fw_version'] = f'{major}.{minor}.{patch}'
            data['port_fw_version_raw'] = fw_ver

        if 'PortControllerNPDOs' in active_port:
            data['port_npdos'] = active_port['PortControllerNPDOs']

        if 'PortControllerNEprPDOs' in active_port:
            data['port_nepr_pdos'] = active_port['PortControllerNEprPDOs']

        if 'PortControllerPowerState' in active_port:
            data['port_power_state'] = active_port['PortControllerPowerState']

        if 'PortControllerPortMode' in active_port:
            mode = active_port['PortControllerPortMode']
            # Mode meanings: 0=DFP, 1=UFP, 2=DRP
            mode_map = {0: 'DFP (Downstream Facing Port)', 1: 'UFP (Upstream Facing Port)', 2: 'DRP (Dual Role Port)'}
            data['port_mode'] = mode_map.get(mode, f'Mode {mode}')
            data['port_mode_raw'] = mode

        if 'PortControllerMaxPower' in active_port:
            max_power_mw = active_port['PortControllerMaxPower']
            data['port_max_power_w'] = max_power_mw / 1000.0
            data['port_max_power_mw'] = max_power_mw

        # Active RDO
        rdo = active_port.get('PortControllerActiveContractRdo', 0)
        if rdo != 0:
            rdo_decoded = self.decode_rdo(rdo)
            data['active_rdo'] = rdo_decoded

        # Port PDOs (sink capabilities)
        # Prefer non-active ports for sink capabilities as they have the full laptop spec
        # The active charging port may have negotiated/reduced values
        port_pdos = None
        max_pdos = 0

        # First, try non-active ports (they have the full capability spec)
        for idx, port in enumerate(port_info):
            if idx == active_port_idx:
                continue  # Skip active port
            pdos = port.get('PortControllerPortPDO', [])
            pdo_count = len([p for p in pdos if p != 0])
            if pdo_count > max_pdos:
                port_pdos = pdos
                max_pdos = pdo_count

        # Fallback to active port if no other ports have PDOs
        if port_pdos is None:
            port_pdos = active_port.get('PortControllerPortPDO', [])

        if port_pdos:
            decoded_pdos = []
            for pdo in port_pdos:
                decoded = self.decode_pdo(pdo)
                if decoded:
                    decoded_pdos.append(decoded)
            if decoded_pdos:
                data['sink_capabilities'] = decoded_pdos

        # Source capabilities from UsbHvcMenu (charger capabilities)
        if 'AdapterDetails' in battery:
            adapter = battery['AdapterDetails']
            if 'UsbHvcMenu' in adapter:
                menu = adapter['UsbHvcMenu']
                source_caps = []
                for item in menu:
                    if 'MaxVoltage' in item and 'MaxCurrent' in item:
                        voltage_mv = item['MaxVoltage']
                        current_ma = item['MaxCurrent']
                        source_caps.append({
                            'voltage_v': voltage_mv / 1000.0,
                            'current_a': current_ma / 1000.0,
                            'power_w': (voltage_mv * current_ma) / 1000000.0,
                            'voltage_mv': voltage_mv,
                            'current_ma': current_ma
                        })
                if source_caps:
                    data['source_capabilities'] = source_caps

        return data

    def get_cable_info(self) -> Dict[str, Any]:
        """Get USB-C cable information from ioreg (eMarker data)"""
        data = {}

        # Try AppleTypeCConnector first
        ioreg_data = self.get_ioreg_data('AppleTypeCConnector', use_archive=True)

        # Fallback to AppleSmartBattery
        if not ioreg_data or not isinstance(ioreg_data, list) or len(ioreg_data) == 0:
            ioreg_data = self.get_ioreg_data('AppleSmartBattery', use_archive=True)

        if not ioreg_data or not isinstance(ioreg_data, list) or len(ioreg_data) == 0:
            return {}

        # Search recursively for cable-related keys
        def search_keys(obj, keys_to_find):
            """Recursively search for keys in nested dict/list structure"""
            results = {}
            if isinstance(obj, dict):
                for key, value in obj.items():
                    if key in keys_to_find and value not in (None, '', [], {}):
                        results[key] = value
                    if isinstance(value, (dict, list)):
                        results.update(search_keys(value, keys_to_find))
            elif isinstance(obj, list):
                for item in obj:
                    results.update(search_keys(item, keys_to_find))
            return results

        # Search for cable keys
        cable_keys = [
            'CableType', 'CableMaxCurrent', 'CableCurrent',
            'CableMaxVoltage', 'CableVoltage', 'CableMaxPower', 'CablePower',
            'CableVendorID', 'CableProductID',
            'IDHeaderVDO', 'IdHeaderVDO', 'IdentityVDO',
            'CertStatVDO', 'CertificateVDO',
            'ProductVDO', 'ProductTypeVDO',
            'CableVDO', 'CableVDO1', 'CableVDO2'
        ]

        found = search_keys(ioreg_data, cable_keys)

        # Cable Type
        if 'CableType' in found:
            data['cable_type'] = found['CableType']

        # Cable Current
        cable_current_ma = found.get('CableMaxCurrent') or found.get('CableCurrent')
        if cable_current_ma and isinstance(cable_current_ma, (int, float)):
            data['cable_current_ma'] = int(cable_current_ma)

        # Cable Voltage
        cable_voltage_mv = found.get('CableMaxVoltage') or found.get('CableVoltage')
        if cable_voltage_mv and isinstance(cable_voltage_mv, (int, float)):
            data['cable_voltage_mv'] = int(cable_voltage_mv)

        # Cable Power
        cable_power_w = found.get('CableMaxPower') or found.get('CablePower')
        if cable_power_w and isinstance(cable_power_w, (int, float)):
            data['cable_power_w'] = int(cable_power_w)

        # Calculate power if we have voltage and current
        if 'cable_current_ma' in data and 'cable_voltage_mv' in data and 'cable_power_w' not in data:
            power_w = (data['cable_current_ma'] * data['cable_voltage_mv']) / 1000000.0
            data['cable_power_w'] = power_w

        # Cable VID:PID
        if 'CableVendorID' in found and isinstance(found['CableVendorID'], int):
            data['cable_vid'] = found['CableVendorID']
        if 'CableProductID' in found and isinstance(found['CableProductID'], int):
            data['cable_pid'] = found['CableProductID']

        # VDOs (Vendor Defined Objects)
        vdo_idhdr = found.get('IDHeaderVDO') or found.get('IdHeaderVDO') or found.get('IdentityVDO')
        if vdo_idhdr and isinstance(vdo_idhdr, int):
            data['vdo_id_header'] = vdo_idhdr

        vdo_cert = found.get('CertStatVDO') or found.get('CertificateVDO')
        if vdo_cert and isinstance(vdo_cert, int):
            data['vdo_cert_stat'] = vdo_cert

        vdo_prod = found.get('ProductVDO') or found.get('ProductTypeVDO')
        if vdo_prod and isinstance(vdo_prod, int):
            data['vdo_product'] = vdo_prod

        vdo_cable = found.get('CableVDO') or found.get('CableVDO1')
        if vdo_cable and isinstance(vdo_cable, int):
            data['vdo_cable'] = vdo_cable

        return data

    def print_header(self, text: str):
        """Print a section header"""
        print(f"\n{Colors.BOLD}{Colors.BLUE}{text}{Colors.RESET}")
        print(f"{Colors.DIM}{'=' * 50}{Colors.RESET}")

    def print_row(self, label: str, value: str, color: str = ''):
        """Print a key-value row"""
        colored_label = f"{Colors.BOLD}{Colors.CYAN}{label:<22}{Colors.RESET}"
        colored_value = f"{color}{value}{Colors.RESET}" if color else value
        print(f"{colored_label} {colored_value}")

    def colorize_yes_no(self, value: str) -> str:
        """Colorize yes/no values"""
        value_lower = value.lower()
        if value_lower in ['yes', 'true', '1', 'ac power']:
            return f"{Colors.GREEN}{value}{Colors.RESET}"
        elif value_lower in ['no', 'false', '0', 'battery power']:
            return f"{Colors.RED}{value}{Colors.RESET}"
        return value

    def colorize_percent(self, percent: int) -> str:
        """Colorize percentage values"""
        if percent >= 90:
            color = Colors.GREEN
        elif percent >= 80:
            color = Colors.YELLOW
        else:
            color = Colors.RED
        return f"{color}{percent}%{Colors.RESET}"

    def display_basic_info(self):
        """Display basic battery information (no sudo required)"""
        print(f"{Colors.BOLD}{Colors.GREEN}macOS Battery Information (Basic Mode){Colors.RESET}")
        print(f"{Colors.BOLD}{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{Colors.RESET}")

        # Get pmset data
        pmset_data = self.get_pmset_battery()
        sp_data = self.get_system_profiler_power()

        self.print_header("Battery Status")
        if 'percent' in pmset_data:
            self.print_row("Current Charge:", self.colorize_percent(pmset_data['percent']))
        if 'status' in pmset_data:
            self.print_row("Status:", pmset_data['status'])
        if 'power_source' in pmset_data:
            self.print_row("Power Source:", self.colorize_yes_no(pmset_data['power_source']))
        if 'time_remaining' in pmset_data:
            self.print_row("Time Remaining:", pmset_data['time_remaining'])

        self.print_header("Battery Health")
        if 'condition' in sp_data:
            self.print_row("Condition:", sp_data['condition'])

        self.print_header("Charger Information")
        if 'connected' in sp_data:
            self.print_row("Connected:", self.colorize_yes_no(sp_data['connected']))
        if 'wattage' in sp_data:
            self.print_row("Wattage:", f"{sp_data['wattage']}W")

        print(f"\n{Colors.YELLOW}Note: Run with --sudo for detailed information{Colors.RESET}")

    def display_detailed_info(self):
        """Display detailed battery and charger information (requires sudo)"""
        print(f"{Colors.BOLD}{Colors.GREEN}macOS Battery and Charger Information (Detailed Mode){Colors.RESET}")
        print(f"{Colors.BOLD}{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{Colors.RESET}")

        # Get all data sources
        pmset_data = self.get_pmset_battery()
        sp_data = self.get_system_profiler_power()
        ioreg_data = self.get_battery_from_ioreg()
        power_data = self.get_powermetrics()
        brightness = self.get_display_brightness()
        usb_ports = self.get_usb_port_limits()
        usbc_pd = self.get_usbc_pd_info()
        cable_info = self.get_cable_info()
        power_mgmt = self.get_power_management_settings()  # Tier 3.1
        hardware_info = self.get_system_hardware_info()  # Phase 1 Enhancement
        scheduled_events = self.get_scheduled_power_events()  # Phase 1 Enhancement

        # System Hardware Information (Phase 1 Enhancement)
        if hardware_info:
            self.print_header("System Information")
            if 'model_identifier' in hardware_info:
                self.print_row("Mac Model:", hardware_info['model_identifier'])
            if 'chip' in hardware_info:
                self.print_row("Chip:", hardware_info['chip'])
            if 'memory' in hardware_info:
                self.print_row("RAM:", hardware_info['memory'])
            if 'physical_cpu_cores' in hardware_info and 'logical_cpu_cores' in hardware_info:
                phys = hardware_info['physical_cpu_cores']
                log = hardware_info['logical_cpu_cores']
                self.print_row("CPU Cores:", f"{phys} physical, {log} logical")
            elif 'physical_cpu_cores' in hardware_info:
                self.print_row("CPU Cores:", f"{hardware_info['physical_cpu_cores']}")

        # Summary (USB-C PD Contract)
        if ('adapter_voltage_mv' in ioreg_data and 'adapter_current_ma' in ioreg_data) or 'adapter_watts' in ioreg_data:
            self.print_header("Summary")
            if 'adapter_voltage_mv' in ioreg_data and 'adapter_current_ma' in ioreg_data:
                v = ioreg_data['adapter_voltage_mv'] / 1000.0
                a = ioreg_data['adapter_current_ma'] / 1000.0
                w = ioreg_data.get('adapter_watts', int(v * a))
                self.print_row("USB-C PD Contract:", f"{v:.2f} V @ {a:.2f} A ({w} W)")

        # Battery Status
        self.print_header("Battery Status")
        if 'percent' in pmset_data:
            self.print_row("Current Charge:", self.colorize_percent(pmset_data['percent']))
        if 'status' in pmset_data:
            self.print_row("Status:", pmset_data['status'])
        if 'power_source' in pmset_data:
            self.print_row("Power Source:", self.colorize_yes_no(pmset_data['power_source']))
        if 'is_charging' in ioreg_data:
            charging_str = "Yes" if ioreg_data['is_charging'] else "No"
            self.print_row("Charging:", self.colorize_yes_no(charging_str))

            # Show time to full when charging, time remaining when discharging
            if ioreg_data['is_charging']:
                if 'avg_time_to_full_decoded' in ioreg_data:
                    self.print_row("Avg Time to Full:", ioreg_data['avg_time_to_full_decoded'])
                elif 'avg_time_to_full_min' in ioreg_data:
                    minutes = ioreg_data['avg_time_to_full_min']
                    self.print_row("Time to Full:", f"~{minutes} minutes")
            else:
                if 'avg_time_to_empty_decoded' in ioreg_data:
                    self.print_row("Avg Time to Empty:", ioreg_data['avg_time_to_empty_decoded'])
                elif 'time_remaining_min' in ioreg_data:
                    minutes = ioreg_data['time_remaining_min']
                    self.print_row("Time Remaining:", f"~{minutes} minutes")

        # Battery Health
        self.print_header("Battery Health")
        if 'condition' in sp_data:
            self.print_row("Condition:", sp_data['condition'])
        # Task 1: Service Recommended indicator
        if 'service_recommended' in sp_data:
            service = sp_data['service_recommended']
            if service:
                self.print_row("Service Recommended:", f"{Colors.RED}Yes{Colors.RESET}")
            else:
                self.print_row("Service Recommended:", f"{Colors.GREEN}No{Colors.RESET}")
        if 'max_capacity' in ioreg_data:
            self.print_row("Maximum Capacity:", f"{ioreg_data['max_capacity']}%")
        if 'cycle_count' in ioreg_data:
            self.print_row("Cycle Count:", f"{ioreg_data['cycle_count']} cycles")
        if 'design_cycle_count_decoded' in ioreg_data:
            self.print_row("Design Cycle Count:", ioreg_data['design_cycle_count_decoded'])
            print(f"{Colors.DIM}                       Expected battery lifespan{Colors.RESET}")
        # Task 2: Expected Lifespan % (calculated from cycle count vs design)
        if 'cycle_count' in ioreg_data and 'design_cycle_count' in ioreg_data:
            cycles = ioreg_data['cycle_count']
            design_cycles = ioreg_data['design_cycle_count']
            if design_cycles > 0:
                lifespan_pct = (cycles / design_cycles) * 100
                # Color coding: Green (<25%), Yellow (25-75%), Red (>75%)
                if lifespan_pct < 25:
                    color = Colors.GREEN
                elif lifespan_pct <= 75:
                    color = Colors.YELLOW
                else:
                    color = Colors.RED
                self.print_row("Lifespan Used:", f"{color}{lifespan_pct:.1f}%{Colors.RESET} ({cycles} / {design_cycles} cycles)")
        if 'fcc_mah' in ioreg_data:
            self.print_row("Battery FCC:", f"{ioreg_data['fcc_mah']} mAh")
        if 'design_capacity' in ioreg_data:
            self.print_row("Design Capacity:",
                           f"{ioreg_data['design_capacity']} mAh")
        if 'nominal_charge_capacity' in ioreg_data:
            self.print_row("Nominal Capacity:",
                           f"{ioreg_data['nominal_charge_capacity']} mAh")
        if 'health_percent' in ioreg_data:
            self.print_row("Health Percentage:", self.colorize_percent(ioreg_data['health_percent']))

        # Capacity Analysis - show relationships between capacity metrics
        if 'design_capacity' in ioreg_data and 'fcc_mah' in ioreg_data:
            design = ioreg_data['design_capacity']
            fcc = ioreg_data['fcc_mah']
            nominal = ioreg_data.get('nominal_charge_capacity', 0)

            if design > 0 and fcc > 0:
                self.print_row("", "")  # Blank line
                self.print_row(f"{Colors.DIM}Capacity Analysis:{Colors.RESET}", "")

                # Design capacity as baseline (100%)
                self.print_row("  Design (factory):", f"{design} mAh (100%)")

                # Nominal capacity (if available)
                if nominal > 0:
                    nom_pct = (nominal / design) * 100.0
                    nom_loss = design - nominal
                    self.print_row("  Nominal (rated):", f"{nominal} mAh ({nom_pct:.1f}%) [-{nom_loss} mAh]")

                # Current FCC (actual maximum)
                fcc_pct = (fcc / design) * 100.0
                fcc_loss = design - fcc
                color = Colors.GREEN if fcc_pct >= 90 else Colors.YELLOW if fcc_pct >= 80 else Colors.RED
                self.print_row("  Current Max (FCC):", f"{color}{fcc} mAh ({fcc_pct:.1f}%){Colors.RESET} [-{fcc_loss} mAh degradation]")

        if 'temp_c' in ioreg_data:
            self.print_row("Temperature:", f"{ioreg_data['temp_c']:.1f}°C")

        # Tier 3.1: Additional battery diagnostics
        if 'current_capacity_mah' in ioreg_data:
            self.print_row("Current Capacity:", f"{ioreg_data['current_capacity_mah']} mAh")
        if 'absolute_capacity' in ioreg_data:
            self.print_row("Absolute Capacity:", f"{ioreg_data['absolute_capacity']}")
        if 'cell_count' in ioreg_data:
            self.print_row("Cell Count:", f"{ioreg_data['cell_count']} cells")
        if 'pack_reserve_decoded' in ioreg_data:
            self.print_row("Pack Reserve:", ioreg_data['pack_reserve_decoded'])
            print(f"{Colors.DIM}                       Capacity reserved by battery management{Colors.RESET}")
        if 'battery_chemistry' in ioreg_data:
            self.print_row("Chemistry:", ioreg_data['battery_chemistry'])
        if 'at_critical_level' in ioreg_data:
            critical = "Yes" if ioreg_data['at_critical_level'] else "No"
            color = Colors.RED if ioreg_data['at_critical_level'] else Colors.GREEN
            self.print_row("At Critical Level:", f"{color}{critical}{Colors.RESET}")
        if 'estimated_cycles_remaining' in ioreg_data:
            cycles_left = ioreg_data['estimated_cycles_remaining']
            self.print_row("Est. Cycles to 80%:", f"{cycles_left} cycles")

        # Tier 3.3A: Cell-Level Diagnostics
        if 'cell_voltages_mv' in ioreg_data:
            voltages = ioreg_data['cell_voltages_mv']
            voltage_str = ", ".join([f"{v}mV" for v in voltages])
            self.print_row("Cell Voltages:", voltage_str)
            if 'cell_voltage_delta_mv' in ioreg_data:
                delta = ioreg_data['cell_voltage_delta_mv']
                if 'cell_imbalance_warning' in ioreg_data:
                    self.print_row("Cell Voltage Delta:", f"{Colors.YELLOW}{delta}mV (IMBALANCE WARNING){Colors.RESET}")
                else:
                    color = Colors.YELLOW if delta > 30 else Colors.GREEN
                    self.print_row("Cell Voltage Delta:", f"{color}{delta}mV{Colors.RESET}")

        # Tier 3.3B: Battery Reliability Metrics
        if 'battery_cell_disconnect_count' in ioreg_data:
            count = ioreg_data['battery_cell_disconnect_count']
            color = Colors.RED if count > 0 else Colors.GREEN
            self.print_row("Cell Disconnect Count:", f"{color}{count}{Colors.RESET}")
        if 'battery_rsense_open_count' in ioreg_data:
            count = ioreg_data['battery_rsense_open_count']
            color = Colors.RED if count > 0 else Colors.GREEN
            self.print_row("R-sense Open Count:", f"{color}{count}{Colors.RESET}")
        if 'permanent_failure_decoded' in ioreg_data:
            decoded = ioreg_data['permanent_failure_decoded']
            color = Colors.RED if "⚠️" in decoded else Colors.GREEN
            self.print_row("Permanent Failure:", f"{color}{decoded}{Colors.RESET}")
        elif 'permanent_failure_status' in ioreg_data:
            status = ioreg_data['permanent_failure_status']
            color = Colors.RED if status != 0 else Colors.GREEN
            self.print_row("Permanent Failure:", f"{color}{status}{Colors.RESET}")
        if 'data_flash_write_count' in ioreg_data:
            self.print_row("Gauge Write Count:", f"{ioreg_data['data_flash_write_count']}")

        # Tier 3.3C: Manufacturing & Provenance
        if 'battery_manufacturer' in ioreg_data:
            self.print_row("Battery Mfg:", ioreg_data['battery_manufacturer'])
        if 'battery_model_mfg' in ioreg_data:
            model_str = ioreg_data['battery_model_mfg']
            if 'battery_revision_mfg' in ioreg_data:
                model_str += f" (rev {ioreg_data['battery_revision_mfg']})"
            self.print_row("Battery Model (Mfg):", model_str)
        if 'design_cycle_count' in ioreg_data:
            design_cycles = ioreg_data['design_cycle_count']
            actual_cycles = ioreg_data.get('cycle_count', 0)
            pct_used = (actual_cycles / design_cycles * 100) if design_cycles > 0 else 0
            self.print_row("Rated Cycle Life:", f"{design_cycles} cycles ({pct_used:.1f}% used)")

        # Manufacture date (decoded from TI battery chip format)
        if 'manufacture_date' in ioreg_data:
            self.print_row("Manufacture Date:", ioreg_data['manufacture_date'])

        # Chemistry ID (decoded)
        if 'chem_id_decoded' in ioreg_data:
            self.print_row("Battery Chemistry:", ioreg_data['chem_id_decoded'])

        # Tier 3.3D: SOC & Charge Analysis
        if 'gauge_soc_pct' in ioreg_data:
            gauge_soc = ioreg_data['gauge_soc_pct']
            reported_soc = pmset_data.get('percent', 0)
            if abs(gauge_soc - reported_soc) > 5:
                self.print_row("Gauge SOC:", f"{Colors.YELLOW}{gauge_soc}% (reported: {reported_soc}%){Colors.RESET}")
            else:
                self.print_row("Gauge SOC:", f"{gauge_soc}%")
        if 'daily_max_soc' in ioreg_data and 'daily_min_soc' in ioreg_data:
            max_soc = ioreg_data['daily_max_soc']
            min_soc = ioreg_data['daily_min_soc']
            self.print_row("Daily Charge Range:", f"{min_soc}% - {max_soc}%")
        # Carrier Mode (Shipping/Storage Mode)
        if 'carrier_mode_decoded' in ioreg_data:
            decoded = ioreg_data['carrier_mode_decoded']
            color = Colors.YELLOW if "Active" in decoded else Colors.GREEN
            self.print_row("Shipping Mode:", f"{color}{decoded}{Colors.RESET}")
        elif 'carrier_mode_status' in ioreg_data:
            status = ioreg_data['carrier_mode_status']
            if status == 0:
                self.print_row("Shipping Mode:", f"{Colors.GREEN}Disabled{Colors.RESET}")
            else:
                self.print_row("Shipping Mode:", f"{Colors.YELLOW}Active{Colors.RESET}")

        # Tier 3.3E: Power Telemetry
        if 'accumulated_system_energy' in ioreg_data:
            # Raw value - units unknown, show as-is
            energy = ioreg_data['accumulated_system_energy']
            # Try to convert to kWh (assuming it's in some reasonable unit)
            if energy > 1000000:
                kwh = energy / 1000000000  # Guess: could be in mWh or similar
                self.print_row("Lifetime Energy:", f"~{kwh:.1f} kWh (est)")

        # Tier 3.3F & 3.3G: Advanced Battery Diagnostics (show if available)
        show_advanced_section = (
            'weighted_ra' in ioreg_data or
            'virtual_temp_c' in ioreg_data or
            'gauge_qmax' in ioreg_data or
            'gauge_flag_decoded' in ioreg_data or
            'misc_status_decoded' in ioreg_data or
            'post_charge_wait_decoded' in ioreg_data or
            'post_discharge_wait_decoded' in ioreg_data or
            'battery_invalid_wake_decoded' in ioreg_data or
            'best_adapter_index' in ioreg_data or
            'charge_accum_mah' in ioreg_data or
            'cycle_count_last_qmax' in ioreg_data or
            ('charger_inhibit_reason' in ioreg_data and
             ioreg_data['charger_inhibit_reason'] != 0)
        )

        if show_advanced_section and self.use_sudo:
            self.print_header("Advanced Battery Diagnostics")

            # Internal Resistance (Tier 3.3F)
            if 'weighted_ra' in ioreg_data:
                ra_values = ioreg_data['weighted_ra']
                if isinstance(ra_values, list) and len(ra_values) > 0:
                    avg_ra = sum(ra_values) / len(ra_values)
                    # Internal resistance in milliohms - lower is better
                    # Good: <100mΩ, Fair: 100-150mΩ, Poor: >150mΩ
                    if avg_ra < 100:
                        status = f"{Colors.GREEN}Excellent{Colors.RESET}"
                    elif avg_ra < 150:
                        status = f"{Colors.YELLOW}Fair{Colors.RESET}"
                    else:
                        status = f"{Colors.RED}High{Colors.RESET}"
                    self.print_row("Internal Resistance:", f"{avg_ra:.1f} mΩ ({status})")
                    print(f"{Colors.DIM}                       Lower resistance = better battery health{Colors.RESET}")

            # Gauge-Measured Max Capacity (Tier 3.3F)
            if 'gauge_qmax' in ioreg_data and isinstance(ioreg_data['gauge_qmax'], list):
                qmax_values = ioreg_data['gauge_qmax']
                if len(qmax_values) > 0:
                    avg_qmax = sum(qmax_values) / len(qmax_values)
                    fcc = ioreg_data.get('fcc_mah', 0)
                    # Compare gauge measurement to reported FCC
                    if fcc > 0:
                        diff_pct = abs((avg_qmax - fcc) / fcc * 100)
                        if diff_pct < 5:
                            note = "(matches FCC)"
                        else:
                            note = f"(FCC: {fcc} mAh, {diff_pct:.1f}% diff)"
                    else:
                        note = ""
                    self.print_row("Gauge Measured Qmax:", f"{avg_qmax:.0f} mAh {note}")

            # Virtual Temperature (Tier 3.3F)
            # Only show when battery is actively discharging or charging (most useful under load)
            if 'virtual_temp_c' in ioreg_data:
                vtemp = ioreg_data['virtual_temp_c']
                actual_temp = ioreg_data.get('temp_c', 0)
                diff = vtemp - actual_temp

                # Check if battery is active (charging or discharging)
                is_charging = ioreg_data.get('is_charging', False)
                current_ma = ioreg_data.get('amperage', 0)
                battery_active = is_charging or abs(current_ma) > 100  # Active if >100mA draw

                # Only show if: battery is active AND temp is realistic AND difference is reasonable
                # Virtual temp is most meaningful under load/discharge, unreliable when idle at 100%
                if battery_active and (-20 <= vtemp <= 80 and abs(diff) > 2 and abs(diff) < 10):
                    self.print_row("Virtual Temperature:", f"{vtemp:.1f}°C (calc: {diff:+.1f}°C from sensor)")
                    print(f"{Colors.DIM}                       Calculated temp based on load & discharge{Colors.RESET}")

            # Best Charger Port (Tier 3.3G)
            if 'best_adapter_index' in ioreg_data:
                idx = ioreg_data['best_adapter_index']
                self.print_row("Best Charger Port:", f"USB-C Port {idx}")
                print(f"{Colors.DIM}                       Port with highest power capability{Colors.RESET}")

            # Gauge Status Flags (Tier 3.3F)
            if 'gauge_flag_decoded' in ioreg_data:
                flags_str = ioreg_data['gauge_flag_decoded']
                # Color code based on flags
                if 'Fully Charged' in flags_str or 'Qualified for Use' in flags_str:
                    color = Colors.GREEN
                elif 'Alarm' in flags_str or 'Inhibit' in flags_str:
                    color = Colors.YELLOW
                else:
                    color = ""
                self.print_row("Gauge Status:", f"{color}{flags_str}{Colors.RESET}")
                print(f"{Colors.DIM}                       Battery gauge chip status flags{Colors.RESET}")

            # Miscellaneous Status (Tier 3.3F)
            if 'misc_status_decoded' in ioreg_data:
                status_str = ioreg_data['misc_status_decoded']
                self.print_row("Misc Status:", status_str)
                print(f"{Colors.DIM}                       ⚠️  Bit meanings undocumented by Apple{Colors.RESET}")

            # Wait Times (Tier 3.3F)
            if 'post_charge_wait_decoded' in ioreg_data:
                wait_str = ioreg_data['post_charge_wait_decoded']
                self.print_row("Post-Charge Wait:", wait_str)
                print(f"{Colors.DIM}                       Rest time after charging before measurement{Colors.RESET}")
            if 'post_discharge_wait_decoded' in ioreg_data:
                wait_str = ioreg_data['post_discharge_wait_decoded']
                self.print_row("Post-Discharge Wait:", wait_str)
                print(f"{Colors.DIM}                       Rest time after discharge before measurement{Colors.RESET}")
            if 'battery_invalid_wake_decoded' in ioreg_data:
                wake_str = ioreg_data['battery_invalid_wake_decoded']
                self.print_row("Invalid Wake Time:", wake_str)
                print(f"{Colors.DIM}                       Time battery stayed awake when it shouldn't{Colors.RESET}")

            # Tier 3.4: Charge Accumulated
            if 'charge_accum_mah' in ioreg_data:
                charge_accum = ioreg_data['charge_accum_mah']
                self.print_row("Charge Accumulated:",
                               f"{charge_accum} mAh")
                print(f"{Colors.DIM}                       "
                      f"Total charge accumulated in battery{Colors.RESET}")

            # Tier 3.4: Last Qmax Calibration
            if 'cycle_count_last_qmax' in ioreg_data:
                last_qmax = ioreg_data['cycle_count_last_qmax']
                if 'cycles_since_qmax_cal' in ioreg_data:
                    cycles_since = ioreg_data['cycles_since_qmax_cal']
                    self.print_row("Last Calibration:",
                                   f"{cycles_since} cycles ago "
                                   f"(at cycle {last_qmax})")
                    print(f"{Colors.DIM}                       "
                          f"Cycles since battery capacity recalibration"
                          f"{Colors.RESET}")
                else:
                    self.print_row("Last Calibration:",
                                   f"at cycle {last_qmax}")

            # Charger Inhibit Reason (Tier 3.3G)
            if 'charger_inhibit_reason' in ioreg_data:
                reason = ioreg_data['charger_inhibit_reason']
                if reason != 0:
                    reason_str = self._decode_charger_inhibit_reason(reason)
                    self.print_row("Charge Inhibited:", f"{Colors.YELLOW}{reason_str}{Colors.RESET}")
                    print(f"{Colors.DIM}                       Why charging is currently restricted{Colors.RESET}")

        # Electrical Information
        self.print_header("Electrical Information")
        if 'voltage_v' in ioreg_data:
            self.print_row("Voltage:", f"{ioreg_data['voltage_v']:.2f}V ({ioreg_data['voltage_mv']} mV)")
        if 'amperage_ma' in ioreg_data:
            amp_ma = ioreg_data['amperage_ma']
            if amp_ma > 0:
                self.print_row("Current (Avg):", f"{Colors.GREEN}+{ioreg_data['amperage_a']:.2f}A ({amp_ma} mA) (charging){Colors.RESET}")
            elif amp_ma < 0:
                self.print_row("Current (Avg):", f"{Colors.RED}{ioreg_data['amperage_a']:.2f}A ({amp_ma} mA) (discharging){Colors.RESET}")
            else:
                self.print_row("Current (Avg):", "0 mA (idle)")

        # Tier 3.1: Instantaneous current
        if 'instant_amperage_ma' in ioreg_data:
            inst_ma = ioreg_data['instant_amperage_ma']
            inst_a = ioreg_data['instant_amperage_a']
            if inst_ma > 0:
                self.print_row("Current (Instant):", f"{Colors.GREEN}+{inst_a:.2f}A ({inst_ma} mA){Colors.RESET}")
            elif inst_ma < 0:
                self.print_row("Current (Instant):", f"{Colors.RED}{inst_a:.2f}A ({inst_ma} mA){Colors.RESET}")
            else:
                self.print_row("Current (Instant):", "0 mA")

        # Tier 3.4: Filtered current (smoothed reading)
        if 'filtered_current_ma' in ioreg_data:
            filt_ma = ioreg_data['filtered_current_ma']
            filt_a = ioreg_data['filtered_current_a']
            if filt_ma > 0:
                self.print_row("Current (Filtered):",
                               f"{Colors.GREEN}+{filt_a:.2f}A "
                               f"({filt_ma} mA){Colors.RESET}")
            elif filt_ma < 0:
                self.print_row("Current (Filtered):",
                               f"{Colors.RED}{filt_a:.2f}A "
                               f"({filt_ma} mA){Colors.RESET}")
            else:
                self.print_row("Current (Filtered):", "0 mA (idle)")

        if 'battery_charge_power_w' in ioreg_data:
            self.print_row("Battery Charge Power:", f"{ioreg_data['battery_charge_power_w']:.1f}W")

        # Charger Information
        if 'external_connected' in ioreg_data or 'connected' in sp_data:
            self.print_header("Charger Information")

            ext_conn = ioreg_data.get('external_connected', False) or sp_data.get('connected', 'No') == 'Yes'
            conn_str = "Yes" if ext_conn else "No"
            self.print_row("Connected:", self.colorize_yes_no(conn_str))

            if ext_conn:
                # Charging Type: Wireless vs Wired
                if 'is_wireless_charging' in ioreg_data:
                    if ioreg_data['is_wireless_charging']:
                        charging_type = f"{Colors.CYAN}MagSafe Wireless{Colors.RESET}"
                    else:
                        charging_type = "USB-C Wired"
                    self.print_row("Charging Type:", charging_type)

                if 'adapter_watts' in ioreg_data:
                    self.print_row("Wattage:", f"{ioreg_data['adapter_watts']}W")
                elif 'wattage' in sp_data:
                    self.print_row("Wattage:", f"{sp_data['wattage']}W")

                # Calculated wattage from V×I
                if 'adapter_voltage_mv' in ioreg_data and 'adapter_current_ma' in ioreg_data:
                    calc_w = (ioreg_data['adapter_voltage_mv'] * ioreg_data['adapter_current_ma']) / 1000000.0
                    self.print_row("Wattage (calc):", f"{calc_w:.1f}W")

                if 'adapter_description' in ioreg_data:
                    self.print_row("Type:", ioreg_data['adapter_description'])

                # Active Voltage Profile Index
                # Shows which profile from the UsbHvcMenu is currently active
                if 'active_voltage_profile_index' in ioreg_data:
                    idx = ioreg_data['active_voltage_profile_index']
                    # If we have the actual profile details, show them
                    if all(k in ioreg_data for k in ['active_profile_voltage_mv',
                                                       'active_profile_current_ma',
                                                       'active_profile_power_w']):
                        v = ioreg_data['active_profile_voltage_mv'] / 1000.0
                        a = ioreg_data['active_profile_current_ma'] / 1000.0
                        w = ioreg_data['active_profile_power_w']
                        self.print_row("Active Profile:",
                                      f"Index {idx} ({v:.0f}V @ {a:.2f}A, {w}W)")
                    else:
                        # Fallback: just show the index
                        self.print_row("Active Profile Index:", str(idx))

                if 'adapter_voltage_mv' in ioreg_data:
                    v = ioreg_data['adapter_voltage_mv'] / 1000.0
                    self.print_row("Voltage:", f"{v:.1f}V")

                if 'adapter_current_ma' in ioreg_data:
                    a = ioreg_data['adapter_current_ma'] / 1000.0
                    self.print_row("Current:", f"{a:.2f}A")

                # Calculated adapter current limit from wattage/voltage
                wattage_val = ioreg_data.get('adapter_watts') or sp_data.get('wattage')
                voltage_val = ioreg_data.get('adapter_voltage_mv')
                if wattage_val and voltage_val and voltage_val > 0:
                    current_limit = (wattage_val * 1000.0) / voltage_val
                    self.print_row("Current Limit (calc):", f"{current_limit:.2f}A")

                if 'charger_family' in sp_data:
                    decoded_family = self._decode_charger_family(sp_data['charger_family'])
                    self.print_row("Charger Family:", decoded_family)

                if 'charger_id' in sp_data:
                    # Show decoded charger ID if available, otherwise just hex
                    if 'charger_id_decoded' in sp_data:
                        self.print_row("Charger ID:", sp_data['charger_id_decoded'])
                    else:
                        self.print_row("Charger ID:", sp_data['charger_id'])

                if 'not_charging_reason' in ioreg_data:
                    reason = ioreg_data['not_charging_reason']
                    reason_str = self._decode_not_charging_reason(reason)
                    # Color code if not charging normally
                    if reason == 0:
                        self.print_row("Not Charging Reason:", reason_str)
                    else:
                        self.print_row("Not Charging Reason:", f"{Colors.YELLOW}{reason_str}{Colors.RESET}")

                # Tier 3.1: Charging diagnostics
                if 'fast_charging' in ioreg_data and ioreg_data['fast_charging']:
                    self.print_row("Charging Mode:", f"{Colors.GREEN}Fast Charging (>20W){Colors.RESET}")
                elif 'trickle_charging' in ioreg_data and ioreg_data['trickle_charging']:
                    self.print_row("Charging Mode:", f"{Colors.YELLOW}Trickle Charging (<5W){Colors.RESET}")

                # Charging Efficiency - moved to after adapter input calculation for accuracy

                if 'charge_limit' in ioreg_data:
                    limit = ioreg_data['charge_limit']
                    self.print_row("Charge Limit:", f"{limit}%")

                if 'battery_inhibit_charge' in ioreg_data:
                    inhibit = ioreg_data['battery_inhibit_charge']
                    inhibit_str = "Yes" if inhibit else "No"
                    color = Colors.YELLOW if inhibit else Colors.GREEN
                    self.print_row("Charging Inhibited:", f"{color}{inhibit_str}{Colors.RESET}")

                if 'optimized_battery_charging' in ioreg_data:
                    obc = ioreg_data['optimized_battery_charging']
                    obc_str = "Enabled" if obc else "Disabled"
                    self.print_row("Optimized Charging:", obc_str)
                    if 'optimized_charging_engaged' in ioreg_data and ioreg_data['optimized_charging_engaged']:
                        self.print_row("", f"{Colors.YELLOW}(Currently engaged){Colors.RESET}")

                # Tier 3.2: Charging Analysis
                if 'charging_voltage_v' in ioreg_data:
                    cv = ioreg_data['charging_voltage_v']
                    bv = ioreg_data.get('voltage_v', 0)
                    if bv > 0:
                        self.print_row("Charging Voltage:", f"{cv:.2f}V (battery: {bv:.2f}V)")
                    else:
                        self.print_row("Charging Voltage:", f"{cv:.2f}V")

                if 'max_charge_current_a' in ioreg_data:
                    mcc = ioreg_data['max_charge_current_a']
                    actual_current = ioreg_data.get('amperage_a', 0)
                    if actual_current > 0:
                        pct = (actual_current / mcc * 100) if mcc > 0 else 0
                        self.print_row("Max Charge Current:", f"{mcc:.2f}A (actual: {actual_current:.2f}A, {pct:.0f}%)")
                    else:
                        self.print_row("Max Charge Current:", f"{mcc:.2f}A")

                # Slow Charging Reason (decoded)
                if 'slow_charging_reason_decoded' in ioreg_data:
                    decoded = ioreg_data['slow_charging_reason_decoded']
                    color = Colors.YELLOW if "0x" in decoded and decoded.split('(')[0].strip() != "None" else Colors.GREEN
                    self.print_row("Slow Charging Reason:", f"{color}{decoded}{Colors.RESET}")
                elif 'slow_charging_reason' in ioreg_data:
                    reason = ioreg_data['slow_charging_reason']
                    reason_hex = f"0x{reason:X}"
                    color = Colors.YELLOW if reason > 0 else Colors.GREEN
                    self.print_row("Slow Charging Reason:", f"{color}{reason_hex}{Colors.RESET}")

                if 'time_charging_thermally_limited' in ioreg_data:
                    minutes = ioreg_data['time_charging_thermally_limited']
                    if minutes > 0:
                        hours = minutes / 60.0
                        color = Colors.YELLOW if minutes > 30 else Colors.GREEN
                        self.print_row("Thermal Limit Time:", f"{color}{minutes} min ({hours:.1f} hrs){Colors.RESET}")

                if 'charger_configuration' in ioreg_data:
                    config = ioreg_data['charger_configuration']
                    decoded_config = self._decode_charger_config(config)
                    self.print_row("Charger Config:", decoded_config)

                if 'external_charge_capable' in ioreg_data:
                    capable = ioreg_data['external_charge_capable']
                    capable_str = "Yes" if capable else "No"
                    self.print_row("External Charge:", self.colorize_yes_no(capable_str))

                if 'max_system_power_w' in ioreg_data:
                    self.print_row("Max System Power:", f"{ioreg_data['max_system_power_w']}W")

                # Estimate total adapter input (when adapter is connected)
                # This includes: System Power + Battery Charging + Display + Overhead
                if ext_conn and power_data:
                    adapter_input_w = 0.0

                    # System power (CPU + GPU + ANE + DRAM)
                    total_system_power = (
                        power_data.get('cpu_power_w', 0.0) +
                        power_data.get('gpu_power_w', 0.0) +
                        power_data.get('ane_power_w', 0.0) +
                        power_data.get('dram_power_w', 0.0)
                    )
                    adapter_input_w += total_system_power

                    # Battery charging power (when charging)
                    if 'battery_charge_power_w' in ioreg_data:
                        adapter_input_w += ioreg_data['battery_charge_power_w']

                    # Display backlight power estimate
                    if brightness is not None:
                        display_power = self.estimate_display_power(brightness)
                        adapter_input_w += display_power

                    # Add overhead for charging inefficiency and other components
                    # Typical charging efficiency is 85-90%, so add ~10-15% overhead
                    # Also accounts for motherboard, fans, ports, etc.
                    overhead_factor = 1.12  # 12% overhead
                    adapter_input_w *= overhead_factor

                    # Prefer actual adapter input from PowerTelemetryData if available
                    actual_adapter_input = ioreg_data.get('system_power_in_w')
                    if actual_adapter_input and actual_adapter_input > 0:
                        adapter_input_w = actual_adapter_input
                        self.print_row("Adapter Input:", f"{adapter_input_w:.1f}W")
                        self.print_row("", f"{Colors.DIM}(Real-time from PowerTelemetryData){Colors.RESET}")
                    elif adapter_input_w > 0:
                        self.print_row("Adapter Input (est):", f"{adapter_input_w:.1f}W")
                        self.print_row("", f"{Colors.DIM}(System + Battery + Display + Overhead){Colors.RESET}")

                    # Adapter Efficiency: AC to DC conversion efficiency (Phase 2, TODO #3.2)
                    # Shows how efficient the power adapter itself is
                    # Only show when loss is meaningful (> 0.5W) to avoid noise
                    if 'adapter_efficiency_loss_w' in ioreg_data and actual_adapter_input and actual_adapter_input > 0:
                        loss_w = ioreg_data['adapter_efficiency_loss_w']
                        # Only display if loss is positive and significant (>0.5W)
                        # When battery is idle/full, loss is typically <0.5W (unreliable)
                        if loss_w > 0.5:
                            # AC input = DC output + Loss
                            # Efficiency = DC output / AC input = DC / (DC + Loss)
                            ac_input_w = actual_adapter_input + loss_w
                            if ac_input_w > 0:
                                adapter_eff = (actual_adapter_input / ac_input_w) * 100.0
                                # Sanity check: efficiency should be < 100%
                                if adapter_eff < 100.0:
                                    # Typical adapter efficiency: 85-92%
                                    if adapter_eff >= 88:
                                        color = Colors.GREEN
                                    elif adapter_eff >= 80:
                                        color = Colors.YELLOW
                                    else:
                                        color = Colors.RED
                                    self.print_row("Adapter Efficiency:", f"{color}{adapter_eff:.1f}%{Colors.RESET} ({loss_w:.1f}W loss)")
                                    self.print_row("", f"{Colors.DIM}(AC to DC conversion efficiency){Colors.RESET}")

                    # Charging Efficiency: What % of adapter input goes to battery
                    if adapter_input_w > 0 and 'battery_charge_power_w' in ioreg_data and ioreg_data['battery_charge_power_w'] > 0:
                        battery_power = ioreg_data['battery_charge_power_w']
                        eff = (battery_power / adapter_input_w) * 100.0
                        if eff >= 85:
                            color = Colors.GREEN
                        elif eff >= 70:
                            color = Colors.YELLOW
                        else:
                            color = Colors.RED
                        self.print_row("Charging Efficiency:", f"{color}{eff:.1f}%{Colors.RESET}")
                        self.print_row("", f"{Colors.DIM}(Battery charge / Total adapter input){Colors.RESET}")

        # Power Breakdown (if available)
        if power_data:
            self.print_header("Power Breakdown")
            # Always show all power metrics, defaulting to 0.0W if not available
            cpu_power = power_data.get('cpu_power_w', 0.0)
            gpu_power = power_data.get('gpu_power_w', 0.0)
            ane_power = power_data.get('ane_power_w', 0.0)
            dram_power = power_data.get('dram_power_w', 0.0)

            self.print_row("CPU Power:", f"{cpu_power:.1f}W")
            self.print_row("GPU Power:", f"{gpu_power:.1f}W")
            self.print_row("ANE Power:", f"{ane_power:.1f}W")
            self.print_row("DRAM Power:", f"{dram_power:.1f}W")

            # Tier 3.2: Advanced Power Metrics
            if 'soc_power_w' in power_data:
                self.print_row("SoC Power:", f"{power_data['soc_power_w']:.1f}W")
            if 'combined_power_w' in power_data:
                self.print_row("Combined Power:", f"{power_data['combined_power_w']:.1f}W")
            if 'package_power_w' in power_data:
                self.print_row("Package Power:", f"{power_data['package_power_w']:.1f}W")
            if 'disk_power_w' in power_data:
                self.print_row("Disk Power:", f"{power_data['disk_power_w']:.1f}W")
            if 'network_power_w' in power_data:
                self.print_row("Network Power:", f"{power_data['network_power_w']:.1f}W")
            if 'peripheral_power_w' in power_data:
                self.print_row("Peripheral Power:", f"{power_data['peripheral_power_w']:.1f}W")

            # Calculate and display total system power
            total_power = cpu_power + gpu_power + ane_power + dram_power
            self.print_row("Total System Power:", f"{total_power:.1f}W")

            # Tier 3.1: Thermal Pressure Level
            # Display thermal pressure with color coding based on severity
            if 'thermal_pressure' in power_data:
                pressure = power_data['thermal_pressure']
                # Color coding: Normal/Nominal = GREEN, Light/Moderate = YELLOW, Heavy = RED
                if pressure.lower() in ['normal', 'nominal']:
                    color = Colors.GREEN
                elif pressure.lower() in ['light', 'moderate']:
                    color = Colors.YELLOW
                elif pressure.lower() == 'heavy':
                    color = Colors.RED
                else:
                    color = Colors.RESET  # Unknown value
                self.print_row("Thermal Pressure:", f"{color}{pressure}{Colors.RESET}")

            # Tier 3.2: Derived metrics
            if 'peak_component_power_w' in power_data:
                self.print_row("Peak Component:", f"{power_data['peak_component_power_w']:.1f}W")
            if 'idle_power_estimate_w' in power_data:
                self.print_row("Idle Power (est):", f"{power_data['idle_power_estimate_w']:.1f}W")

            # Real-Time Power Flow (from PowerTelemetryData)
            if ioreg_data:
                flow_metrics = []
                if 'system_power_in_w' in ioreg_data:
                    flow_metrics.append(('system_power_in_w', 'Adapter Power In:'))
                if 'battery_power_w' in ioreg_data:
                    flow_metrics.append(('battery_power_w', 'Battery Power:'))
                if 'system_load_w' in ioreg_data:
                    flow_metrics.append(('system_load_w', 'System Load:'))
                # Only show adapter loss if positive (negative values are measurement noise)
                if 'adapter_efficiency_loss_w' in ioreg_data and ioreg_data['adapter_efficiency_loss_w'] > 0:
                    flow_metrics.append(('adapter_efficiency_loss_w', 'Adapter Loss:'))

                if flow_metrics:
                    self.print_row(f"{Colors.DIM}Real-Time Power Flow:{Colors.RESET}", "")
                    for key, label in flow_metrics:
                        value = ioreg_data[key]
                        # Color code battery power: green for charging, red for discharging
                        if key == 'battery_power_w':
                            if value > 0:
                                color = Colors.GREEN
                                sign = "+"
                            elif value < 0:
                                color = Colors.RED
                                sign = ""
                            else:
                                color = Colors.RESET
                                sign = ""
                            self.print_row(f"  {label}", f"{color}{sign}{value:.1f}W{Colors.RESET}")
                        else:
                            self.print_row(f"  {label}", f"{value:.1f}W")

                # Phase 1: Additional real-time power metrics
                # Only show wall power if it's greater than system power (sanity check)
                if 'wall_energy_estimate_w' in ioreg_data and ioreg_data['wall_energy_estimate_w'] > 0:
                    wall_w = ioreg_data['wall_energy_estimate_w']
                    system_power = ioreg_data.get('system_power_in_w', 0)
                    # Wall power must be >= system power (accounting for adapter losses)
                    if wall_w >= system_power * 0.9:  # Allow 10% margin for measurement variance
                        self.print_row("  Wall AC Power:", f"{wall_w:.1f}W")
                        self.print_row("", f"{Colors.DIM}    (Estimated at wall outlet){Colors.RESET}")

                # Show real-time voltage/current if available
                if 'system_voltage_in_v' in ioreg_data and 'system_current_in_a' in ioreg_data:
                    voltage_v = ioreg_data['system_voltage_in_v']
                    current_a = ioreg_data['system_current_in_a']
                    current_ma = ioreg_data.get('system_current_in_ma', 0)
                    if voltage_v > 0 and current_ma > 0:
                        self.print_row("  Adapter Live:", f"{voltage_v:.2f}V @ {current_a:.3f}A ({current_ma} mA)")
                        self.print_row("", f"{Colors.DIM}    (Real-time voltage/current){Colors.RESET}")

                # Power Accounting Summary
                # Show where the adapter/system power is going
                if 'system_load_w' in ioreg_data and ioreg_data['system_load_w'] > 0:
                    total_load = ioreg_data['system_load_w']
                    accounted = 0.0

                    self.print_row("", "")  # Blank line
                    self.print_row(f"{Colors.DIM}Power Distribution:{Colors.RESET}", "")

                    # Component power (CPU/GPU/ANE/DRAM)
                    component_power = power_data.get('combined_power_w', 0.0)
                    if component_power > 0:
                        pct = (component_power / total_load * 100) if total_load > 0 else 0
                        self.print_row("  Components:", f"{component_power:.1f}W ({pct:.0f}%)")
                        self.print_row("", f"{Colors.DIM}    CPU/GPU/ANE/DRAM{Colors.RESET}")
                        accounted += component_power

                    # Display power
                    if brightness is not None:
                        display_power = (brightness / 100.0) * 6.0
                        pct = (display_power / total_load * 100) if total_load > 0 else 0
                        self.print_row("  Display:", f"{display_power:.1f}W ({pct:.0f}%)")
                        self.print_row("", f"{Colors.DIM}    Backlight @ {brightness:.0f}%{Colors.RESET}")
                        accounted += display_power

                    # Battery charging (if charging)
                    if 'battery_power_w' in ioreg_data and ioreg_data['battery_power_w'] > 0:
                        battery_power = ioreg_data['battery_power_w']
                        pct = (battery_power / total_load * 100) if total_load > 0 else 0
                        self.print_row("  Battery Charging:", f"{battery_power:.1f}W ({pct:.0f}%)")
                        accounted += battery_power

                    # Other/unaccounted (SSD, WiFi, Thunderbolt, USB devices, etc.)
                    other = max(0, total_load - accounted)
                    if other > 0.1:
                        pct = (other / total_load * 100) if total_load > 0 else 0
                        self.print_row("  Other Components:", f"{other:.1f}W ({pct:.0f}%)")
                        self.print_row("", f"{Colors.DIM}    SSD, WiFi, Thunderbolt, USB, etc.{Colors.RESET}")

                    # Total
                    self.print_row("  Total System Load:", f"{Colors.BOLD}{total_load:.1f}W{Colors.RESET}")

        # Display
        if brightness is not None:
            self.print_header("Display")
            self.print_row("Display Brightness:", f"{brightness:.0f}%")

            # Display Panel Power Estimation (Phase 2, TODO #1.2)
            # Typical MacBook displays consume 4-8W at max brightness
            # Using 6W as average maximum, scaled by brightness percentage
            display_power_w = (brightness / 100.0) * 6.0
            self.print_row("Display Power (est):", f"{display_power_w:.1f}W")
            self.print_row("", f"{Colors.DIM}(Estimated: {brightness:.0f}% × 6W max){Colors.RESET}")

        # USB Ports
        if usb_ports:
            self.print_header("USB Ports")
            if 'wake_current_ma' in usb_ports:
                ma = usb_ports['wake_current_ma']
                a = ma / 1000.0
                self.print_row("USB Wake Current:", f"{a:.2f} A ({ma} mA)")
            if 'sleep_current_ma' in usb_ports:
                ma = usb_ports['sleep_current_ma']
                a = ma / 1000.0
                self.print_row("USB Sleep Current:", f"{a:.2f} A ({ma} mA)")

        # Tier 3.1: Power Management Settings
        if power_mgmt:
            self.print_header("Power Management")

            if 'low_power_mode' in power_mgmt:
                lpm = power_mgmt['low_power_mode']
                lpm_str = "Enabled" if lpm else "Disabled"
                color = Colors.YELLOW if lpm else Colors.GREEN
                self.print_row("Low Power Mode:", f"{color}{lpm_str}{Colors.RESET}")

            if 'hibernation_mode' in power_mgmt:
                hib_mode = power_mgmt['hibernation_mode']
                hib_modes = {
                    0: "No hibernation",
                    3: "Safe sleep (default)",
                    25: "Hibernation for desktops"
                }
                hib_str = hib_modes.get(hib_mode, f"Mode {hib_mode}")
                self.print_row("Hibernation Mode:", hib_str)

            if 'standby_delay_high' in power_mgmt or 'standby_delay_low' in power_mgmt:
                if 'standby_delay_high' in power_mgmt:
                    delay = power_mgmt['standby_delay_high']
                    hours = delay / 3600
                    self.print_row("Standby Delay (High):", f"{delay}s ({hours:.1f} hrs)")
                if 'standby_delay_low' in power_mgmt:
                    delay = power_mgmt['standby_delay_low']
                    hours = delay / 3600
                    self.print_row("Standby Delay (Low):", f"{delay}s ({hours:.1f} hrs)")

            if 'wake_on_lan' in power_mgmt:
                wol = power_mgmt['wake_on_lan']
                wol_str = "Enabled" if wol else "Disabled"
                self.print_row("Wake on LAN:", wol_str)

            if 'power_assertions' in power_mgmt and power_mgmt['power_assertions']:
                assertions = power_mgmt['power_assertions']
                self.print_row("Active Assertions:", f"{len(assertions)} active")
                for assertion in assertions[:3]:  # Show first 3
                    simplified_name = self._simplify_assertion_name(assertion['name'])
                    self.print_row("", f"{Colors.DIM}{assertion['type']}: {simplified_name}{Colors.RESET}")
                if len(assertions) > 3:
                    self.print_row("", f"{Colors.DIM}... and {len(assertions)-3} more{Colors.RESET}")

            # Tier 3.2: Additional Power Management Settings
            if 'power_nap' in power_mgmt:
                pn = power_mgmt['power_nap']
                pn_str = "Enabled" if pn else "Disabled"
                self.print_row("Power Nap:", pn_str)

            if 'auto_power_off_delay' in power_mgmt:
                delay = power_mgmt['auto_power_off_delay']
                hours = delay / 3600
                self.print_row("Auto Power Off:", f"{delay}s ({hours:.1f} hrs)")

            if 'display_sleep_minutes' in power_mgmt:
                minutes = power_mgmt['display_sleep_minutes']
                if minutes == 0:
                    self.print_row("Display Sleep:", "Never")
                else:
                    self.print_row("Display Sleep:", f"{minutes} min")

            # Tier 3.2: Power Source History
            if 'power_source_history' in power_mgmt and power_mgmt['power_source_history']:
                history = power_mgmt['power_source_history']
                self.print_row("Power Source History:", f"{len(history)} recent changes")
                for event in history[-3:]:  # Show last 3
                    timestamp = event['timestamp'].split()[1]  # Just time, not date
                    source = event['source']
                    color = Colors.GREEN if 'AC' in source else Colors.YELLOW
                    self.print_row("", f"{Colors.DIM}{timestamp}:{Colors.RESET} {color}{source}{Colors.RESET}")

            # Tier 3.2: Sleep/Wake History
            if 'sleep_wake_history' in power_mgmt and power_mgmt['sleep_wake_history']:
                history = power_mgmt['sleep_wake_history']
                self.print_row("Sleep/Wake History:", f"{len(history)} recent events")
                for event in history[-3:]:  # Show last 3
                    timestamp = event['timestamp'].split()[1]  # Just time, not date
                    event_type = event['event']
                    if event_type == 'Sleep':
                        color = Colors.BLUE
                    elif event_type == 'Wake':
                        color = Colors.GREEN
                    else:  # DarkWake
                        color = Colors.CYAN
                    self.print_row("", f"{Colors.DIM}{timestamp}:{Colors.RESET} {color}{event_type}{Colors.RESET}")

            # Phase 1 Enhancement: Scheduled Power Events
            if scheduled_events and (scheduled_events.get('wake_events') or scheduled_events.get('sleep_events')):
                total_events = len(scheduled_events.get('wake_events', [])) + len(scheduled_events.get('sleep_events', []))
                self.print_row("Scheduled Events:", f"{total_events} upcoming")

                # Show wake events
                for event in scheduled_events.get('wake_events', [])[:3]:  # Show first 3
                    time_str = event['time']
                    reason = event['reason']
                    # Truncate reason if too long
                    if len(reason) > 50:
                        reason = reason[:47] + "..."
                    self.print_row("", f"{Colors.DIM}Wake at {time_str}:{Colors.RESET} {Colors.GREEN}{reason}{Colors.RESET}")

                # Show sleep events
                for event in scheduled_events.get('sleep_events', [])[:3]:  # Show first 3
                    time_str = event['time']
                    reason = event['reason']
                    if len(reason) > 50:
                        reason = reason[:47] + "..."
                    self.print_row("", f"{Colors.DIM}Sleep at {time_str}:{Colors.RESET} {Colors.BLUE}{reason}{Colors.RESET}")

        # USB-C Power Delivery Information
        if usbc_pd:
            self.print_header("USB-C Power Delivery")

            if 'pd_version' in usbc_pd:
                self.print_row("PD Specification:", f"USB PD {usbc_pd['pd_version']}")

            if 'power_role' in usbc_pd:
                self.print_row("Power Role:", usbc_pd['power_role'])

            if 'data_role' in usbc_pd:
                self.print_row("Data Role:", usbc_pd['data_role'])

            # Active RDO (Request Data Object)
            if 'active_rdo' in usbc_pd:
                rdo = usbc_pd['active_rdo']
                self.print_row("Active RDO:", rdo['rdo_hex'])

                if 'object_position' in rdo:
                    self.print_row("Selected PDO:", f"PDO #{rdo['object_position']}")

                if 'operating_current_ma' in rdo:
                    self.print_row("Operating Current:", f"{rdo['operating_current_a']:.2f} A ({rdo['operating_current_ma']} mA)")

                if 'max_current_ma' in rdo:
                    self.print_row("Max Current:", f"{rdo['max_current_a']:.2f} A ({rdo['max_current_ma']} mA)")

            # Port Controller Info
            if 'port_fw_version' in usbc_pd:
                self.print_row("Port FW Version:", usbc_pd['port_fw_version'])

            if 'port_npdos' in usbc_pd:
                self.print_row("Number of PDOs:", str(usbc_pd['port_npdos']))

            if 'port_nepr_pdos' in usbc_pd:
                self.print_row("Number of EPR PDOs:", str(usbc_pd['port_nepr_pdos']))

            if 'port_mode' in usbc_pd:
                self.print_row("Port Mode:", usbc_pd['port_mode'])

            if 'port_power_state' in usbc_pd:
                decoded_state = self._decode_power_state(usbc_pd['port_power_state'])
                self.print_row("Power State:", decoded_state)

            if 'port_max_power_w' in usbc_pd:
                self.print_row("Port Max Power:", f"{usbc_pd['port_max_power_w']:.1f} W")

            # Source Capabilities (what the charger offers)
            if 'source_capabilities' in usbc_pd:
                self.print_header("Source Capabilities (Charger)")
                for idx, cap in enumerate(usbc_pd['source_capabilities'], 1):
                    pdo_type = cap.get('pdo_type', 'Fixed')
                    if pdo_type == 'Fixed':
                        label = f"PDO {idx}:"
                        value = f"{cap['voltage_v']:.2f} V @ {cap['current_a']:.2f} A ({cap['power_w']:.1f} W)"
                        self.print_row(label, value)
                    elif pdo_type == 'PPS':
                        label = f"PDO {idx} (PPS):"
                        value = f"{cap['min_voltage_v']:.1f}-{cap['max_voltage_v']:.1f} V @ {cap['current_a']:.2f} A"
                        self.print_row(label, value)
                        self.print_row("", f"{Colors.DIM}(Programmable Power Supply - variable voltage){Colors.RESET}")

            # Sink Capabilities (what the laptop can accept)
            if 'sink_capabilities' in usbc_pd:
                self.print_header("Sink Capabilities (Laptop)")
                for idx, cap in enumerate(usbc_pd['sink_capabilities'], 1):
                    pdo_type = cap.get('pdo_type', 'Fixed')
                    if pdo_type == 'Fixed':
                        label = f"PDO {idx}:"
                        value = f"{cap['voltage_v']:.2f} V @ {cap['current_a']:.2f} A ({cap['power_w']:.1f} W)"
                        self.print_row(label, value)
                    elif pdo_type == 'PPS':
                        label = f"PDO {idx} (PPS):"
                        value = f"{cap['min_voltage_v']:.1f}-{cap['max_voltage_v']:.1f} V @ {cap['current_a']:.2f} A"
                        self.print_row(label, value)
                        self.print_row("", f"{Colors.DIM}(Programmable Power Supply - variable voltage){Colors.RESET}")

        # Cable Information (eMarker data)
        if cable_info:
            self.print_header("Cable")

            if 'cable_type' in cable_info:
                self.print_row("Cable Type:", str(cable_info['cable_type']))

            if 'cable_current_ma' in cable_info:
                ma = cable_info['cable_current_ma']
                a = ma / 1000.0
                self.print_row("Cable Max Current:", f"{a:.2f} A ({ma} mA)")

            if 'cable_voltage_mv' in cable_info:
                mv = cable_info['cable_voltage_mv']
                v = mv / 1000.0
                self.print_row("Cable Max Voltage:", f"{v:.2f} V ({mv} mV)")

            if 'cable_power_w' in cable_info:
                w = cable_info['cable_power_w']
                self.print_row("Cable Max Power:", f"{w:.1f} W")

            if 'cable_vid' in cable_info and 'cable_pid' in cable_info:
                vid = cable_info['cable_vid']
                pid = cable_info['cable_pid']
                self.print_row("Cable VID:PID:", f"0x{vid:04X}:0x{pid:04X}")
            elif 'cable_vid' in cable_info:
                vid = cable_info['cable_vid']
                self.print_row("Cable VID:", f"0x{vid:04X}")
            elif 'cable_pid' in cable_info:
                pid = cable_info['cable_pid']
                self.print_row("Cable PID:", f"0x{pid:04X}")

            # VDOs (Vendor Defined Objects)
            vdo_parts = []
            if 'vdo_id_header' in cable_info:
                vdo_parts.append(f"IDHeader=0x{cable_info['vdo_id_header']:08X}")
            if 'vdo_cert_stat' in cable_info:
                vdo_parts.append(f"Cert=0x{cable_info['vdo_cert_stat']:08X}")
            if 'vdo_product' in cable_info:
                vdo_parts.append(f"Product=0x{cable_info['vdo_product']:08X}")
            if 'vdo_cable' in cable_info:
                vdo_parts.append(f"Cable=0x{cable_info['vdo_cable']:08X}")

            if vdo_parts:
                self.print_row("Cable VDOs:", ", ".join(vdo_parts))

        # Battery Details
        self.print_header("Battery Details")
        if 'device_name' in sp_data:
            self.print_row("Model:", sp_data['device_name'])
        if 'serial_number' in sp_data:
            self.print_row("Serial Number:", sp_data['serial_number'])
        if 'firmware_version' in sp_data:
            self.print_row("Firmware Version:", sp_data['firmware_version'])
        if 'gas_gauge_fw_decoded' in ioreg_data:
            self.print_row("Gas Gauge FW:", ioreg_data['gas_gauge_fw_decoded'])
        # Task 3: Battery Age in Days
        if 'manufacture_date' in ioreg_data:
            mfg_date_str = ioreg_data['manufacture_date']
            # Parse the date string (format: "YYYY-MM-DD" or "YYYY-MM-DD (Lot: X)")
            try:
                # Extract just the date part (before any parentheses)
                date_part = mfg_date_str.split(' ')[0]  # Get "YYYY-MM-DD"
                mfg_date = datetime.strptime(date_part, "%Y-%m-%d")
                current_date = datetime.now()
                age_days = (current_date - mfg_date).days

                # Convert to human-readable format
                if age_days < 30:
                    age_str = f"{age_days} days"
                elif age_days < 365:
                    months = age_days // 30
                    age_str = f"{age_days} days ({months} months)"
                else:
                    years = age_days / 365.25
                    age_str = f"{age_days} days ({years:.1f} years)"

                self.print_row("Battery Age:", age_str)
            except (ValueError, IndexError):
                # If parsing fails, skip the age calculation
                pass

        # Lifetime Statistics
        if any(key in ioreg_data for key in ['total_operating_time_min', 'max_temp_c', 'min_temp_c', 'avg_temp_c']):
            self.print_header("Lifetime Statistics")
            if 'total_operating_time_min' in ioreg_data:
                minutes = ioreg_data['total_operating_time_min']
                hours = ioreg_data['total_operating_time_hrs']
                self.print_row("Total Operating Time:", f"{minutes} minutes (~{hours:.1f} hours)")
            if 'max_temp_c' in ioreg_data:
                self.print_row("Maximum Temperature:", f"{ioreg_data['max_temp_c']}°C")
            if 'min_temp_c' in ioreg_data:
                self.print_row("Minimum Temperature:", f"{ioreg_data['min_temp_c']}°C")
            if 'avg_temp_c' in ioreg_data:
                self.print_row("Average Temperature:", f"{ioreg_data['avg_temp_c']:.1f}°C")

        # Health Assessment
        self.print_header("Health Assessment")

        # Battery Health Score (composite 0-100)
        # Combines: capacity health, cycle life, cell balance, internal resistance
        if 'health_percent' in ioreg_data and 'cycle_count' in ioreg_data:
            score = 0.0
            factors = []

            # Factor 1: Capacity Health (40% weight)
            capacity_health = ioreg_data['health_percent']
            capacity_score = min(100, capacity_health * 1.0)  # 96% health = 96 points
            score += capacity_score * 0.40
            factors.append(f"Capacity: {capacity_health}%")

            # Factor 2: Cycle Life Remaining (30% weight)
            cycles = ioreg_data['cycle_count']
            design_cycles = ioreg_data.get('design_cycle_count', 1000)
            if design_cycles > 0:
                cycle_life_remaining = max(0, 100 - (cycles / design_cycles * 100))
                score += cycle_life_remaining * 0.30
                factors.append(f"Cycle Life: {cycle_life_remaining:.0f}%")
            else:
                score += 30  # Default if missing

            # Factor 3: Cell Balance (15% weight)
            if 'cell_voltage_delta_mv' in ioreg_data:
                delta = ioreg_data['cell_voltage_delta_mv']
                # Perfect: 0-5mV=100pts, Good: 5-15mV=90pts, Fair: 15-30mV=70pts, Poor: >30mV=50pts
                if delta <= 5:
                    cell_score = 100
                elif delta <= 15:
                    cell_score = 90
                elif delta <= 30:
                    cell_score = 70
                else:
                    cell_score = max(0, 50 - (delta - 30))
                score += cell_score * 0.15
                factors.append(f"Cell Balance: {delta}mV")
            else:
                score += 15  # Default if missing

            # Factor 4: Internal Resistance (15% weight)
            if 'weighted_ra' in ioreg_data:
                ra_values = ioreg_data['weighted_ra']
                if isinstance(ra_values, list) and len(ra_values) > 0:
                    resistance = sum(ra_values) / len(ra_values)
                    # Excellent: <80mΩ=100pts, Good: 80-120mΩ=85pts, Fair: 120-180mΩ=65pts, Poor: >180mΩ=40pts
                    if resistance < 80:
                        resist_score = 100
                    elif resistance < 120:
                        resist_score = 85
                    elif resistance < 180:
                        resist_score = 65
                    else:
                        resist_score = max(0, 40 - (resistance - 180) / 10)
                    score += resist_score * 0.15
                    factors.append(f"Resistance: {resistance:.1f}mΩ")
                else:
                    score += 15  # Default if missing
            else:
                score += 15  # Default if missing

            # Display overall score
            score = min(100, max(0, score))  # Clamp to 0-100
            if score >= 90:
                grade = "A+"
                color = Colors.GREEN
                desc = "Excellent"
            elif score >= 85:
                grade = "A"
                color = Colors.GREEN
                desc = "Very Good"
            elif score >= 80:
                grade = "B+"
                color = Colors.GREEN
                desc = "Good"
            elif score >= 70:
                grade = "B"
                color = Colors.YELLOW
                desc = "Fair"
            elif score >= 60:
                grade = "C"
                color = Colors.YELLOW
                desc = "Aging"
            else:
                grade = "D"
                color = Colors.RED
                desc = "Poor"

            self.print_row("Battery Health Score:", f"{color}{score:.0f}/100{Colors.RESET} ({grade} - {desc})")
            self.print_row("", f"{Colors.DIM}{', '.join(factors)}{Colors.RESET}")
            self.print_row("", "")  # Blank line

        if 'cycle_count' in ioreg_data:
            cycles = ioreg_data['cycle_count']
            if cycles < 100:
                assessment = f"{Colors.GREEN}Excellent{Colors.RESET} ({cycles} cycles - very low)"
            elif cycles < 300:
                assessment = f"{Colors.GREEN}Good{Colors.RESET} ({cycles} cycles - low)"
            elif cycles < 500:
                assessment = f"{Colors.YELLOW}Fair{Colors.RESET} ({cycles} cycles - moderate)"
            elif cycles < 800:
                assessment = f"{Colors.YELLOW}Aging{Colors.RESET} ({cycles} cycles - high)"
            else:
                assessment = f"{Colors.RED}High{Colors.RESET} ({cycles} cycles - consider replacement)"
            self.print_row("Cycle Count:", assessment)

        if 'health_percent' in ioreg_data:
            health = ioreg_data['health_percent']
            if health >= 90:
                assessment = f"{Colors.GREEN}Excellent{Colors.RESET} ({health}% of original)"
            elif health >= 80:
                assessment = f"{Colors.GREEN}Good{Colors.RESET} ({health}% of original)"
            elif health >= 70:
                assessment = f"{Colors.YELLOW}Fair{Colors.RESET} ({health}% of original)"
            else:
                assessment = f"{Colors.RED}Poor{Colors.RESET} ({health}% of original - consider replacement)"
            self.print_row("Capacity:", assessment)

        print(f"\n{Colors.BOLD}Note:{Colors.RESET} MacBook batteries typically maintain good health for 1000+ cycles")

    def display(self):
        """Display information based on privilege level"""
        if self.use_sudo:
            self.display_detailed_info()
        else:
            self.display_basic_info()


def main():
    parser = argparse.ArgumentParser(
        description='macOS Battery and Charger Information Tool',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                  # Basic mode (no sudo required)
  %(prog)s --sudo           # Detailed mode (requires sudo)
  sudo %(prog)s             # Detailed mode (auto-detected)
  %(prog)s --no-color       # Disable colored output
        """
    )

    parser.add_argument(
        '--sudo',
        action='store_true',
        help='Enable detailed mode (requires sudo privileges)'
    )

    parser.add_argument(
        '--no-color',
        action='store_true',
        help='Disable colored output'
    )

    args = parser.parse_args()

    # Auto-detect if running as root
    is_root = os.geteuid() == 0
    use_sudo = args.sudo or is_root

    # Check if sudo is requested but not running as root
    if args.sudo and not is_root:
        print(f"{Colors.YELLOW}Warning: --sudo requested but not running as root. Some information may be unavailable.{Colors.RESET}")
        print(f"{Colors.YELLOW}Try: sudo {' '.join(sys.argv)}{Colors.RESET}\n")

    power_info = PowerInfo(use_sudo=use_sudo, use_colors=not args.no_color)
    power_info.display()


if __name__ == '__main__':
    main()
