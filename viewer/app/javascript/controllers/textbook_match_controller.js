import { Controller } from "@hotwired/stimulus";
export default class extends Controller {
  static targets=["select","feedback"];
  static values={answer:Object};
  connect(){ if(!this.hasAnswerValue) this.answerValue={}; this._say(""); }
  check(){
    const answer=this.answerValue||{};
    let total=0, correct=0;
    this.selectTargets.forEach((sel)=>{
      const leftId=sel.dataset.leftId; if(!leftId) return;
      total+=1;
      const chosen=(sel.value||"").toString();
      const expected=(answer[leftId]||"").toString();
      sel.classList.remove("tb-match-ok","tb-match-bad");
      if(chosen.length===0) return;
      if(chosen===expected && expected.length>0){ correct+=1; sel.classList.add("tb-match-ok"); }
      else { sel.classList.add("tb-match-bad"); }
    });
    if(total===0) return this._say("Nothing to check.");
    this._say(correct===total ? `Perfect — ${correct}/${total}.` : `${correct}/${total} correct. Adjust highlighted ones and try again.`);
  }
  reset(){
    this.selectTargets.forEach((sel)=>{ sel.value=""; sel.classList.remove("tb-match-ok","tb-match-bad"); });
    this._say("Reset.");
  }
  _say(msg){ if(this.hasFeedbackTarget) this.feedbackTarget.textContent=msg; }
}
