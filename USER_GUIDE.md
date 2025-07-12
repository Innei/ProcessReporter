# ProcessReporter User Guide

Welcome to ProcessReporter! This guide will help you get started with monitoring your computer activity and integrating with your favorite services.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Main Features](#main-features)
3. [Configuration Examples](#configuration-examples)
4. [Privacy & Security](#privacy--security)
5. [Integration Setup](#integration-setup)
6. [Frequently Asked Questions](#frequently-asked-questions)
7. [Troubleshooting](#troubleshooting)

---

## Getting Started

### What is ProcessReporter?

ProcessReporter is a macOS menu bar application that tracks your computer activity, including:
- Which applications you're using
- Window titles of active applications
- Media playback information (what music/videos you're playing)
- Time spent on different tasks

This information can be sent to various services like Slack, cloud storage, or your personal blog.

### Installation

1. Download ProcessReporter from the latest release
2. Open the downloaded `.dmg` file
3. Drag ProcessReporter to your Applications folder
4. Launch ProcessReporter from your Applications folder

### First Launch

When you first open ProcessReporter:

1. **Look for the menu bar icon** - You'll see a new icon in your menu bar (top-right of your screen)
   
   ![Menu Bar Icon Placeholder]
   
2. **Grant Permissions** - macOS will ask for accessibility permissions:
   - Click "Open System Settings" when prompted
   - Enable ProcessReporter in Privacy & Security → Accessibility
   - This allows the app to see window titles
   
   ![Permissions Dialog Placeholder]

3. **Configure Your First Integration** - Click the menu bar icon and select "Preferences"

---

## Main Features

### 1. Activity Monitoring

ProcessReporter automatically tracks:

- **Application Usage**: Which apps you have open and focused
- **Window Titles**: What documents, websites, or projects you're working on
- **Media Playback**: Songs, videos, or podcasts you're playing
- **Time Tracking**: How long you spend in each application

![Activity Overview Placeholder]

### 2. Smart Filtering

You can filter what gets tracked:

- **Privacy Mode**: Temporarily pause all tracking
- **Application Filters**: Exclude specific apps from tracking
- **Window Title Filters**: Hide sensitive window titles
- **Domain Filters**: Filter out specific websites

### 3. Activity History

View your past activity:

- See what you worked on throughout the day
- Search through your history
- Export data for personal analysis

![History View Placeholder]

### 4. Multiple Integrations

Send your activity data to:

- **Slack**: Share what you're working on with your team
- **Cloud Storage (S3)**: Backup your activity data
- **MixSpace**: Integrate with your personal blog
- **Custom Webhooks**: Send to any service you like

---

## Configuration Examples

### Example 1: Basic Personal Tracking

Perfect for freelancers or students who want to track their productivity:

1. Open Preferences → General
2. Set report interval to 5 minutes
3. Enable "Track Media Playback" if you want to log music
4. Leave all integrations disabled for local-only tracking

### Example 2: Team Collaboration Setup

Great for remote teams who want to share what they're working on:

1. **Configure Slack Integration**:
   - Go to Preferences → Integrations → Slack
   - Add your Slack webhook URL
   - Set channel to #standup or #working-on
   - Enable "Only during work hours"

2. **Set Work Hours**:
   - Preferences → General → Work Hours
   - Set your typical work schedule
   - Enable "Pause outside work hours"

3. **Filter Personal Apps**:
   - Preferences → Filters
   - Add personal apps like Spotify, Messages, etc.
   - These won't be shared with your team

### Example 3: Content Creator Setup

For bloggers, streamers, or content creators:

1. **Enable Media Tracking**:
   - Track what music you're listening to
   - Share currently playing media with your audience

2. **Configure MixSpace/Blog Integration**:
   - Add your blog's API endpoint
   - Set update frequency to match your needs
   - Enable "Include Media Information"

3. **Custom Window Title Mapping**:
   - Map technical titles to friendly names
   - Example: "Code - project-x" → "Working on Secret Project 🚀"

---

## Privacy & Security

### Best Practices

1. **Review What's Being Tracked**:
   - Regularly check History to see what's being recorded
   - Use Preview in integrations to see what will be sent

2. **Use Filters Liberally**:
   - Filter out banking apps and password managers
   - Hide sensitive project names with window title filters
   - Use domain filters for private websites

3. **Secure Your Integrations**:
   - Keep webhook URLs private
   - Use encrypted connections (HTTPS) only
   - Regularly rotate API keys

4. **Privacy Mode**:
   - Use Privacy Mode (⌘+P in menu) for sensitive work
   - Set up automatic privacy mode for certain apps
   - Configure privacy mode schedule

### What ProcessReporter Does NOT Do

- ❌ Does NOT capture screenshots
- ❌ Does NOT record keystrokes
- ❌ Does NOT access file contents
- ❌ Does NOT track mouse movements
- ✅ Only tracks app names, window titles, and media info

---

## Integration Setup

### Slack Integration

1. **Create a Slack Webhook**:
   - Go to your Slack workspace settings
   - Navigate to "Apps" → "Custom Integrations" → "Incoming Webhooks"
   - Create a new webhook for your desired channel
   - Copy the webhook URL

2. **Configure in ProcessReporter**:
   - Open Preferences → Integrations → Slack
   - Paste your webhook URL
   - Choose a display name and emoji
   - Test with "Send Test Message"

   ![Slack Setup Placeholder]

### S3/Cloud Storage Integration

1. **Prepare Your S3 Bucket**:
   - Create an S3 bucket in AWS Console
   - Create an IAM user with write permissions
   - Generate access keys

2. **Configure in ProcessReporter**:
   - Enter your AWS credentials
   - Specify bucket name and region
   - Choose file format (JSON or CSV)
   - Set backup frequency

### MixSpace Integration

1. **Get Your API Endpoint**:
   - Log into your MixSpace admin panel
   - Navigate to API settings
   - Copy your personal API endpoint

2. **Configure Connection**:
   - Add endpoint URL in preferences
   - Enter your API token
   - Enable "Share Media Playback"
   - Test connection

---

## Frequently Asked Questions

### General Questions

**Q: Does ProcessReporter slow down my computer?**
A: No, ProcessReporter uses minimal resources (less than 50MB RAM and virtually no CPU when idle).

**Q: Can I use ProcessReporter on multiple computers?**
A: Yes! Install it on all your devices. Each will report independently to your configured integrations.

**Q: Is my data stored locally?**
A: Yes, all activity history is stored locally on your computer. Only data you explicitly configure is sent to integrations.

### Privacy Questions

**Q: Can my employer see my personal activity?**
A: Only if you configure it to share. By default, nothing is shared. Use filters to exclude personal apps.

**Q: What happens to filtered applications?**
A: Filtered apps are completely ignored - they're not tracked or stored at all.

**Q: Can I delete my history?**
A: Yes, go to Preferences → History and use the "Clear History" options.

### Integration Questions

**Q: My Slack messages aren't sending. What's wrong?**
A: Check your webhook URL and ensure your Slack workspace allows incoming webhooks. Use "Test Message" to diagnose.

**Q: Can I send to multiple Slack channels?**
A: Currently, you can configure one channel. For multiple channels, consider using Slack workflows to redistribute messages.

**Q: How often does data sync to cloud storage?**
A: Based on your configuration - typically every hour for S3. You can also trigger manual exports.

---

## Troubleshooting

### Common Issues

#### ProcessReporter doesn't see window titles

**Solution**:
1. Open System Settings → Privacy & Security → Accessibility
2. Ensure ProcessReporter is listed and enabled
3. If not listed, drag ProcessReporter from Applications folder to the list
4. Restart ProcessReporter

#### Menu bar icon disappeared

**Solution**:
1. Check if ProcessReporter is running (look in Activity Monitor)
2. If not running, launch from Applications
3. If running but no icon, quit and restart the app
4. Check menu bar settings - you might have too many icons

#### Integration not working

**For Slack**:
- Verify webhook URL is correct (no extra spaces)
- Check if your Slack workspace allows webhooks
- Try the "Test Message" button
- Check your internet connection

**For S3**:
- Verify AWS credentials are correct
- Ensure bucket exists and is accessible
- Check IAM permissions include PutObject
- Verify region matches your bucket

#### High memory usage

**Solution**:
1. Clear old history data (Preferences → History)
2. Reduce report frequency
3. Disable unused integrations
4. Restart the application

### Getting Help

If you're still having issues:

1. **Check the Logs**:
   - Menu Bar → View Logs
   - Look for error messages
   
2. **Report an Issue**:
   - Include your macOS version
   - Describe what you expected vs what happened
   - Include relevant log entries

3. **Privacy-Safe Debugging**:
   - Enable debug mode without sharing sensitive data
   - Use test integration endpoints
   - Clear history after testing

---

## Tips & Tricks

### Power User Features

1. **Keyboard Shortcuts**:
   - `⌘+P` - Toggle Privacy Mode
   - `⌘+,` - Open Preferences
   - `⌘+H` - View History

2. **Custom Mappings**:
   - Create friendly names for technical windows
   - Use emoji to make reports more fun
   - Set up project-specific aliases

3. **Automation Ideas**:
   - Use with time tracking tools
   - Create daily summary reports
   - Integrate with your task management system

### Best Practices

1. **Start Simple**:
   - Begin with just local tracking
   - Add integrations one at a time
   - Fine-tune filters as needed

2. **Regular Maintenance**:
   - Review filters monthly
   - Clear old history quarterly
   - Update integration credentials as needed

3. **Team Usage**:
   - Agree on sharing conventions
   - Respect privacy boundaries
   - Use consistent naming for shared projects

---

## Need More Help?

- Visit our [GitHub repository](https://github.com/your-repo/ProcessReporter) for updates
- Check [Discussions](https://github.com/your-repo/ProcessReporter/discussions) for community help
- Report bugs in [Issues](https://github.com/your-repo/ProcessReporter/issues)

Thank you for using ProcessReporter! We hope it helps you understand and share your work better. 🎯