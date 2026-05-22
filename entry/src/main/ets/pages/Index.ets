import { AbilityConstant, appManager, common, Configuration, EnvironmentCallback } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const EVENT_LIFECYCLE_SIGNAL: string = 'lifecycleHub.signal';

class LifecycleSignal {
  channel: string;
  state: string;
  detail: string;
  pressure: number;
  at: string;

  constructor(channel: string, state: string, detail: string, pressure: number, at: string) {
    this.channel = channel;
    this.state = state;
    this.detail = detail;
    this.pressure = pressure;
    this.at = at;
  }
}

class EventLog {
  id: number;
  channel: string;
  state: string;
  detail: string;
  at: string;

  constructor(id: number, channel: string, state: string, detail: string, at: string) {
    this.id = id;
    this.channel = channel;
    this.state = state;
    this.detail = detail;
    this.at = at;
  }
}

class ProcessRow {
  pid: number;
  uid: number;
  processName: string;
  bundleName: string;
  state: string;

  constructor(pid: number, uid: number, processName: string, bundleName: string, state: string) {
    this.pid = pid;
    this.uid = uid;
    this.processName = processName;
    this.bundleName = bundleName;
    this.state = state;
  }
}

class HubEnvironmentCallback extends EnvironmentCallback {
  private readonly onConfig: (config: Configuration) => void;
  private readonly onMemory: (level: AbilityConstant.MemoryLevel) => void;

  constructor(onConfig: (config: Configuration) => void, onMemory: (level: AbilityConstant.MemoryLevel) => void) {
    super();
    this.onConfig = onConfig;
    this.onMemory = onMemory;
  }

  onConfigurationUpdated(config: Configuration): void {
    this.onConfig(config);
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.onMemory(level);
  }
}

@Entry
@Component
struct Index {
  @State activeTab: number = 0;
  @State eventCount: number = 0;
  @State lifecycleState: string = 'Booting';
  @State eventHubState: string = 'Preparing';
  @State environmentState: string = 'Not registered';
  @State memoryLevel: string = 'Moderate';
  @State memoryPressure: number = 24;
  @State appName: string = 'com.example.applifecyclehub';
  @State processName: string = 'entry';
  @State cacheSummary: string = 'Cache pending';
  @State processCount: number = 0;
  @State latestEvent: string = 'Waiting for EventHub traffic';
  @State configSummary: string = 'No configuration update';
  @State manualStep: number = 0;
  @State eventFlow: EventLog[] = [
    new EventLog(1, 'boot', 'Created', 'ApplicationContext pending', '--:--')
  ];
  @State processes: ProcessRow[] = [
    new ProcessRow(0, 0, 'Loading', 'bundle pending', 'CREATE')
  ];

  private applicationContext?: common.ApplicationContext;
  private eventHub?: common.EventHub;
  private environmentCallback?: EnvironmentCallback;
  private environmentCallbackId: number = -1;
  private refreshTimer: number = -1;
  private readonly reusableDate: Date = new Date(0)

  private readonly stateSubscriber = (payload: Object): void => {
    const signal = payload as LifecycleSignal;
    this.eventCount += 1;
    this.lifecycleState = signal.state;
    this.memoryPressure = signal.pressure;
    this.latestEvent = `${signal.channel}: ${signal.detail}`;
    this.eventFlow = [
      new EventLog(this.eventCount + 1, signal.channel, signal.state, signal.detail, signal.at),
      ...this.eventFlow
    ].slice(0, 6);
  };

  aboutToAppear(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.eventHub) {
      this.eventHub.off(EVENT_LIFECYCLE_SIGNAL, this.stateSubscriber);
    }
    if (this.applicationContext && this.environmentCallbackId >= 0) {
      this.applicationContext.off('environment', this.environmentCallbackId);
      this.environmentCallbackId = -1;
    }
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  async bootstrap(): Promise<void> {
    this.connectApplicationContext();
    this.connectEventHub();
    this.registerEnvironmentCallback();
    await this.refreshProcesses();
    this.emitLifecycleSignal('app', 'Foreground', 'Dashboard mounted', this.memoryPressure);
    this.startProcessTicker();
  }

  connectApplicationContext(): void {
    try {
      const abilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.applicationContext = abilityContext.getApplicationContext();
      this.appName = this.applicationContext.applicationInfo.name;
      this.processName = this.applicationContext.processName;
      this.cacheSummary = this.tailPath(this.applicationContext.cacheDir);
    } catch (error) {
      this.latestEvent = this.errorMessage(error, 'ApplicationContext failed');
    }
  }

  connectEventHub(): void {
    if (!this.applicationContext) {
      return;
    }

    try {
      this.eventHub = this.applicationContext.eventHub;
      this.eventHub.on(EVENT_LIFECYCLE_SIGNAL, this.stateSubscriber);
      this.eventHubState = 'on/off/emit ready';
    } catch (error) {
      this.eventHubState = this.errorMessage(error, 'EventHub failed');
    }
  }

  registerEnvironmentCallback(): void {
    if (!this.applicationContext) {
      return;
    }

    try {
      this.environmentCallback = new HubEnvironmentCallback((config: Configuration) => {
        this.configSummary = this.configurationLabel(config);
        this.emitLifecycleSignal('config', 'Config changed', this.configSummary, this.memoryPressure);
      }, (level: AbilityConstant.MemoryLevel) => {
        this.applyMemoryLevel(level, 'System');
      });
      this.environmentCallbackId = this.applicationContext.on('environment', this.environmentCallback);
      this.environmentState = `Callback #${this.environmentCallbackId}`;
    } catch (error) {
      this.environmentState = this.errorMessage(error, 'Environment failed');
    }
  }

  startProcessTicker(): void {
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      this.refreshProcesses();
    }, 6000);
  }

  emitLifecycleSignal(channel: string, state: string, detail: string, pressure: number): void {
    if (!this.eventHub) {
      this.latestEvent = 'EventHub not ready';
      return;
    }
    this.eventHub.emit(EVENT_LIFECYCLE_SIGNAL, new LifecycleSignal(channel, state, detail, pressure, this.timeLabel()));
  }

  async refreshProcesses(): Promise<void> {
    if (!this.applicationContext) {
      return;
    }

    try {
      const running = await this.applicationContext.getRunningProcessInformation();
      this.processes = running.map((item: appManager.ProcessInformation) => {
        return new ProcessRow(item.pid, item.uid, item.processName, this.bundleLabel(item.bundleNames),
          this.processStateLabel(item.state));
      });
      this.processCount = this.processes.length;
      this.emitLifecycleSignal('process', 'Scan complete', `${this.processCount} running process`, this.memoryPressure);
    } catch (error) {
      this.latestEvent = this.errorMessage(error, 'Process scan failed');
    }
  }

  publishStateEvent(): void {
    const nextState = this.lifecycleState === 'Foreground' ? 'Active' : 'Foreground';
    this.emitLifecycleSignal('state', nextState, `Manual publish #${this.eventCount + 1}`, this.memoryPressure);
  }

  simulateMemoryPressure(): void {
    const levels: AbilityConstant.MemoryLevel[] = [
      AbilityConstant.MemoryLevel.MEMORY_LEVEL_MODERATE,
      AbilityConstant.MemoryLevel.MEMORY_LEVEL_LOW,
      AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL
    ];
    const level = levels[this.manualStep % levels.length];
    this.manualStep += 1;
    this.applyMemoryLevel(level, 'Manual');
  }

  applyMemoryLevel(level: AbilityConstant.MemoryLevel, source: string): void {
    this.memoryLevel = this.memoryLabel(level);
    this.memoryPressure = this.pressureValue(level);
    this.emitLifecycleSignal('memory', this.memoryLevel, `${source} pressure ${this.memoryPressure}%`,
      this.memoryPressure);
  }

  switchTab(index: number): void {
    this.activeTab = index;
    const detail = index === 0 ? 'Event flow selected' : 'Process topology selected';
    this.emitLifecycleSignal('ui', index === 0 ? 'Flow view' : 'Topology view', detail, this.memoryPressure);
  }

  bundleLabel(bundleNames: Array<string>): string {
    if (bundleNames.length === 0) {
      return this.appName;
    }
    return bundleNames[0];
  }

  processStateLabel(state: appManager.ProcessState): string {
    if (state === appManager.ProcessState.STATE_ACTIVE) {
      return 'ACTIVE';
    }
    if (state === appManager.ProcessState.STATE_FOREGROUND) {
      return 'FOREGROUND';
    }
    if (state === appManager.ProcessState.STATE_BACKGROUND) {
      return 'BACKGROUND';
    }
    if (state === appManager.ProcessState.STATE_DESTROY) {
      return 'DESTROY';
    }
    return 'CREATE';
  }

  memoryLabel(level: AbilityConstant.MemoryLevel): string {
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL) {
      return 'Critical';
    }
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_LOW) {
      return 'Low';
    }
    return 'Moderate';
  }

  pressureValue(level: AbilityConstant.MemoryLevel): number {
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL) {
      return 92;
    }
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_LOW) {
      return 64;
    }
    return 28;
  }

  memoryColor(): ResourceColor {
    if (this.memoryPressure >= 85) {
      return '#EF4444';
    }
    if (this.memoryPressure >= 60) {
      return '#F59E0B';
    }
    return '#22C55E';
  }

  configurationLabel(config: Configuration): string {
    const parts: string[] = [];
    if (config.language) {
      parts.push(config.language);
    }
    if (config.colorMode !== undefined) {
      parts.push(`color ${config.colorMode}`);
    }
    if (config.direction !== undefined) {
      parts.push(`dir ${config.direction}`);
    }
    if (config.fontSizeScale !== undefined) {
      parts.push(`font ${config.fontSizeScale}`);
    }
    return parts.length > 0 ? parts.join(' / ') : 'Configuration changed';
  }

  errorMessage(error: Object, fallback: string): string {
    const err = error as BusinessError;
    if (err && err.code) {
      return `${fallback}: ${err.code}`;
    }
    return fallback;
  }

  tailPath(path: string): string {
    const segments = path.split('\\');
    if (segments.length < 2) {
      return path;
    }
    return `${segments[segments.length - 2]}\\${segments[segments.length - 1]}`;
  }

  shortText(value: string, maxLength: number = 34): string {
    if (value.length <= maxLength) {
      return value;
    }
    return `${value.substring(0, maxLength - 1)}...`;
  }

  timeLabel(): string {
    this.reusableDate.setTime(Date.now())
    const hours = this.reusableDate.getHours()
    const rawMinutes = this.reusableDate.getMinutes()
    const minutes = rawMinutes < 10 ? `0${rawMinutes}` : `${rawMinutes}`
    return `${hours}:${minutes}`
  }

  @Builder
  TabButton(label: string, index: number): void {
    Text(label)
      .fontSize(9)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.activeTab === index ? '#07111F' : '#CBD5E1')
      .height(22)
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.activeTab === index ? '#E5E7EB' : '#172033')
      .borderRadius(8)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.switchTab(index);
      })
  }

  @Builder
  StatTile(label: string, value: string, accent: ResourceColor): void {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(7)
        .fontColor('#94A3B8')
        .maxLines(1)
      Text(this.shortText(value, 20))
        .fontSize(9)
        .fontWeight(FontWeight.Medium)
        .fontColor(accent)
        .maxLines(1)
    }
    .height(34)
    .layoutWeight(1)
    .padding({ left: 7, right: 7, top: 4, bottom: 4 })
    .backgroundColor('#101A2B')
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  EventCard(item: EventLog): void {
    Column({ space: 4 }) {
      Row() {
        Text(item.channel)
          .fontSize(8)
          .fontWeight(FontWeight.Bold)
          .fontColor('#38BDF8')
          .maxLines(1)
          .layoutWeight(1)
        Text(item.at)
          .fontSize(8)
          .fontColor('#A7F3D0')
          .maxLines(1)
      }
      .width('100%')

      Text(item.state)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F8FAFC')
        .maxLines(1)

      Text(this.shortText(item.detail, 44))
        .fontSize(8)
        .fontColor('#CBD5E1')
        .maxLines(1)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 7, bottom: 7 })
    .backgroundColor('#111827')
    .borderRadius(8)
    .border({ width: 1, color: '#253044' })
  }

  @Builder
  ProcessCard(item: ProcessRow): void {
    Column({ space: 4 }) {
      Row() {
        Text(`pid ${item.pid}`)
          .fontSize(9)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F8FAFC')
          .maxLines(1)
          .layoutWeight(1)
        Text(item.state)
          .fontSize(7)
          .fontColor('#07111F')
          .height(16)
          .padding({ left: 5, right: 5 })
          .backgroundColor(item.state === 'ACTIVE' ? '#22C55E' : '#F59E0B')
          .borderRadius(8)
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      Text(this.shortText(item.processName, 36))
        .fontSize(8)
        .fontColor('#93C5FD')
        .maxLines(1)
      Text(this.shortText(item.bundleName, 36))
        .fontSize(8)
        .fontColor('#CBD5E1')
        .maxLines(1)
      Text(`uid ${item.uid}`)
        .fontSize(8)
        .fontColor('#A7F3D0')
        .maxLines(1)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 7, bottom: 7 })
    .backgroundColor('#111827')
    .borderRadius(8)
    .border({ width: 1, color: '#253044' })
  }

  @Builder
  FlowTab(): void {
    Scroll() {
      Column({ space: 6 }) {
        Column({ space: 5 }) {
          Row({ space: 5 }) {
            this.StatTile('EventHub', this.eventHubState, '#38BDF8')
            this.StatTile('Env', this.environmentState, '#A7F3D0')
          }
          .width('100%')

          Row({ space: 5 }) {
            this.StatTile('Memory', this.memoryLevel, this.memoryColor())
            this.StatTile('Config', this.configSummary, '#FDE68A')
          }
          .width('100%')
        }
        .width('100%')

        ForEach(this.eventFlow, (item: EventLog) => {
          this.EventCard(item)
        }, (item: EventLog) => `${item.id}`)
      }
      .width('100%')
      .padding({ bottom: 18 })
    }
    .width('78%')
    .layoutWeight(1)
  }

  @Builder
  ProcessTab(): void {
    Scroll() {
      Column({ space: 6 }) {
        this.StatTile('ApplicationContext', this.shortText(this.appName, 26), '#38BDF8')
        this.StatTile('Process', this.shortText(this.processName, 26), '#A7F3D0')
        this.StatTile('Cache', this.cacheSummary, '#FDE68A')

        ForEach(this.processes, (item: ProcessRow) => {
          this.ProcessCard(item)
        }, (item: ProcessRow) => `${item.pid}-${item.uid}`)
      }
      .width('100%')
      .padding({ bottom: 18 })
    }
    .width('78%')
    .layoutWeight(1)
  }

  @Builder
  BottomAction(label: string, action: () => void): void {
    Text(label)
      .height(26)
      .layoutWeight(1)
      .fontSize(8)
      .fontWeight(FontWeight.Medium)
      .fontColor('#07111F')
      .maxLines(1)
      .textAlign(TextAlign.Center)
      .backgroundColor('#E5E7EB')
      .borderRadius(8)
      .onClick(action)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 6 }) {
        Row() {
          Column({ space: 1 }) {
            Text('Lifecycle Hub')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F8FAFC')
              .maxLines(1)
            Text('HarmonyOS 6.0.1(21)')
              .fontSize(7)
              .fontColor('#94A3B8')
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Stack({ alignContent: Alignment.Center }) {
            Progress({
              value: this.memoryPressure,
              total: 100,
              type: ProgressType.Ring
            })
              .width(34)
              .height(34)
              .color(this.memoryColor())
              .backgroundColor('#253044')

            Text(`${this.eventCount}`)
              .fontSize(9)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F8FAFC')
              .maxLines(1)
          }
        }
        .width('62%')

        Row({ space: 5 }) {
          this.StatTile('State', this.lifecycleState, '#38BDF8')
          this.StatTile('Proc', `${this.processCount}`, '#A7F3D0')
        }
        .width('68%')

        Text(this.shortText(this.latestEvent, 46))
          .width('72%')
          .fontSize(8)
          .fontColor('#CBD5E1')
          .textAlign(TextAlign.Center)
          .maxLines(1)

        Row({ space: 6 }) {
          this.TabButton('Events', 0)
          this.TabButton('Process', 1)
        }
        .width('58%')
        .justifyContent(FlexAlign.Center)

        if (this.activeTab === 0) {
          this.FlowTab()
        } else {
          this.ProcessTab()
        }

        Row({ space: 5 }) {
          this.BottomAction('Emit', () => {
            this.publishStateEvent();
          })
          this.BottomAction('Memory', () => {
            this.simulateMemoryPressure();
          })
          this.BottomAction('Scan', () => {
            this.refreshProcesses();
          })
        }
        .width('72%')
      }
      .width('100%')
      .height('100%')
      .padding({ top: 24, bottom: 22 })
      .alignItems(HorizontalAlign.Center)
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#07111F')
  }
}