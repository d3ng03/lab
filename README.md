# ARTEX 실습 랩

AI 자율 침투테스트 도구 **ARTEX** 를 Vulhub 기반 3-tier 랩에 돌려보는 환경.
두 가지 랩 구성이 있고, `vulhub/`·`ARTEX/`·`artex.lab.yml`·`lab-firewall.sh` 는 둘이 **공유**한다.

| 구성 | 설명 |
|---|---|
| [**lab1/**](lab1/README.md) | 원본 8종. 내부=jenkins·grafana·nexus·nacos, 데이터=mysql·redis·es. |
| [**lab2/**](lab2/README.md) | RCE→RCE→DB 체인. 양다리 브리지를 struts2(S2-045 unauth RCE)로 교체. |

```
lab/
├── vulhub/           # Vulhub 클론 (공유, 원본 수정 안 함)
├── ARTEX/            # ARTEX 클론 (공유) — 직접 클론해서 둘 것
├── artex.lab.yml     # ARTEX 포트를 127.0.0.1 로 묶는 override (공유)
├── lab-firewall.sh   # 격리 방화벽 (root, 공유) — 브리지 기준이라 lab1/lab2 공용
├── lab1/   ├── lab.sh  └── README.md
└── lab2/   ├── lab.sh  └── README.md
```

## 쓰는 법 (한 번에 하나만)

lab1 과 lab2 는 **같은 네트워크 이름/브리지를 쓰므로 동시에 켜지 말 것.** 전환할 땐:

```bash
cd lab/lab1 && ./lab.sh down        # 쓰던 쪽 내리고
cd ../lab2                          # 바꿀 쪽으로 이동
sudo ../lab-firewall.sh apply       # (root) 격리 적용
./lab.sh up                         # 기동
```

ARTEX(및 pgdata), 격리 방화벽, LLM 설정은 공유되므로 전환해도 그대로 유지된다.
각 구성의 상세는 위 lab1/lab2 README 참고.
